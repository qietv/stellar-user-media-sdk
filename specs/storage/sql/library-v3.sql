-- Preserve only the newest unfinished run for each source before enforcing the
-- invariant for databases created by SDK versions that allowed overlap.
UPDATE scan_run AS older
SET state = 'cancelled',
    finished_at_ms = COALESCE(older.finished_at_ms, older.started_at_ms),
    error_code = COALESCE(older.error_code, 'conflict'),
    error_summary = COALESCE(
        older.error_summary,
        'Superseded while enabling the single-active-scan invariant.'
    )
WHERE older.state IN ('queued', 'enumerating', 'processing', 'finalizing')
  AND EXISTS (
      SELECT 1
      FROM scan_run AS newer
      WHERE newer.source_id = older.source_id
        AND newer.state IN ('queued', 'enumerating', 'processing', 'finalizing')
        AND newer.id > older.id
  );

CREATE UNIQUE INDEX uq_scan_run_one_active_source
    ON scan_run(source_id)
    WHERE state IN ('queued', 'enumerating', 'processing', 'finalizing');

-- File facts discovered by an unfinished run remain private until the run can
-- atomically publish a complete authoritative snapshot.
CREATE TABLE scan_discovery (
    run_id              INTEGER NOT NULL REFERENCES scan_run(id) ON DELETE CASCADE,
    stable_key          TEXT NOT NULL,
    generated_uid       TEXT NOT NULL,
    stable_id           TEXT,
    parent_stable_key   TEXT,
    relative_path       TEXT NOT NULL,
    path_compare_key    TEXT NOT NULL,
    display_name        TEXT NOT NULL,
    extension           TEXT,
    size_bytes          INTEGER,
    modified_at_ms      INTEGER,
    etag                TEXT,
    PRIMARY KEY(run_id, stable_key),
    UNIQUE(run_id, path_compare_key)
) WITHOUT ROWID;

PRAGMA user_version = 3;
