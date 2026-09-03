-- Missing-file retention is source-specific. A completed authoritative scan may mark a file
-- missing, but physical cleanup is delayed and suspended while the source is offline.
ALTER TABLE library_source
ADD COLUMN last_successful_scan_at_ms INTEGER
    CHECK (last_successful_scan_at_ms IS NULL OR last_successful_scan_at_ms >= 0);

ALTER TABLE library_source
ADD COLUMN offline_since_ms INTEGER
    CHECK (offline_since_ms IS NULL OR offline_since_ms >= 0);

ALTER TABLE library_source
ADD COLUMN last_error_code TEXT;

ALTER TABLE library_source
ADD COLUMN missing_grace_ms INTEGER NOT NULL DEFAULT 604800000
    CHECK (missing_grace_ms >= 0);

ALTER TABLE library_source
ADD COLUMN missing_required_scan_count INTEGER NOT NULL DEFAULT 2
    CHECK (missing_required_scan_count > 0);

ALTER TABLE library_source
ADD COLUMN missing_empty_root_guard INTEGER NOT NULL DEFAULT 1
    CHECK (missing_empty_root_guard IN (0, 1));

ALTER TABLE library_source
ADD COLUMN missing_drop_guard_percent INTEGER NOT NULL DEFAULT 80
    CHECK (missing_drop_guard_percent BETWEEN 0 AND 100);

ALTER TABLE library_source
ADD COLUMN missing_drop_guard_minimum_count INTEGER NOT NULL DEFAULT 100
    CHECK (missing_drop_guard_minimum_count > 0);

-- Local storage normally has stronger availability guarantees than a network share. Existing
-- sources receive the recommended per-kind defaults during migration; callers may override them.
UPDATE library_source
SET missing_grace_ms = CASE kind
    WHEN 'local_folder' THEN 86400000
    WHEN 'device_media' THEN 86400000
    WHEN 'cloud_drive' THEN 2592000000
    ELSE 604800000
END;

-- Retain the observed file count so a suspicious empty or sharply reduced result must be repeated
-- before it is accepted as authoritative deletion evidence.
ALTER TABLE scan_run
ADD COLUMN observed_file_count INTEGER NOT NULL DEFAULT 0
    CHECK (observed_file_count >= 0);

-- Metadata garbage collection is independent from file availability. The first timestamp starts
-- the seven-day orphan clock; the second is an Infuse-style reversible deletion mark.
ALTER TABLE media_entity
ADD COLUMN orphaned_at_ms INTEGER
    CHECK (orphaned_at_ms IS NULL OR orphaned_at_ms >= 0);

ALTER TABLE media_entity
ADD COLUMN gc_marked_at_ms INTEGER
    CHECK (gc_marked_at_ms IS NULL OR gc_marked_at_ms >= 0);

CREATE INDEX idx_media_file_missing_retention
    ON media_file(source_id, missing_since_ms, missing_scan_count, id)
    WHERE availability = 'missing' AND deleted_at_ms IS NULL;

CREATE INDEX idx_media_file_deleted_retention
    ON media_file(deleted_at_ms, id)
    WHERE availability = 'deleted' AND deleted_at_ms IS NOT NULL;

CREATE INDEX idx_media_entity_gc
    ON media_entity(orphaned_at_ms, gc_marked_at_ms, id)
    WHERE deleted_at_ms IS NULL;

PRAGMA user_version = 10;
