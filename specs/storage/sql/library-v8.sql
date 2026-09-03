-- Preserve scanner-level compound-media classification with the staged file fact so publishing
-- remains atomic. The JSON value is a versioned array because one malformed directory may expose
-- more than one structural candidate until the authoritative parser resolves it.
ALTER TABLE scan_discovery
ADD COLUMN composite_media_json TEXT
    CHECK (
        composite_media_json IS NULL
        OR (
            length(composite_media_json) <= 262144
            AND json_valid(composite_media_json)
            AND json_type(composite_media_json) = 'array'
        )
    );

ALTER TABLE media_file
ADD COLUMN composite_media_json TEXT
    CHECK (
        composite_media_json IS NULL
        OR (
            length(composite_media_json) <= 262144
            AND json_valid(composite_media_json)
            AND json_type(composite_media_json) = 'array'
        )
    );

PRAGMA user_version = 8;
