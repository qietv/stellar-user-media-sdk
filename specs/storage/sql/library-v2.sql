CREATE TABLE scan_frontier (
    run_id              INTEGER NOT NULL REFERENCES scan_run(id) ON DELETE CASCADE,
    directory_json      TEXT NOT NULL,
    cursor_token        TEXT NOT NULL,
    state               TEXT NOT NULL CHECK (state IN ('pending', 'completed')),
    updated_at_ms       INTEGER NOT NULL,
    PRIMARY KEY(run_id, directory_json, cursor_token)
) WITHOUT ROWID;

CREATE INDEX idx_scan_frontier_pending
    ON scan_frontier(run_id, state, directory_json, cursor_token);

CREATE TABLE scan_seen (
    run_id              INTEGER NOT NULL REFERENCES scan_run(id) ON DELETE CASCADE,
    identity_key        TEXT NOT NULL,
    is_directory        INTEGER NOT NULL DEFAULT 0 CHECK (is_directory IN (0, 1)),
    PRIMARY KEY(run_id, identity_key)
) WITHOUT ROWID;

PRAGMA user_version = 2;
