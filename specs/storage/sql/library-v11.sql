-- Deep optical-disc probing is expensive on network sources. Cache both successful projections
-- and typed failures against the exact published file revision and selection rule.
CREATE TABLE composite_media_probe (
    media_file_id          INTEGER PRIMARY KEY
                           REFERENCES media_file(id) ON DELETE CASCADE,
    input_revision         INTEGER NOT NULL CHECK (input_revision > 0),
    input_size_bytes       INTEGER CHECK (input_size_bytes IS NULL OR input_size_bytes >= 0),
    input_modified_at_ms   INTEGER,
    input_etag             TEXT,
    selection_rule_version INTEGER NOT NULL CHECK (selection_rule_version > 0),
    status                 TEXT NOT NULL CHECK (status IN (
                               'confirmed', 'unsupported', 'corrupt_structure', 'encrypted',
                               'cancelled', 'remote_unavailable', 'dependency_failure'
                           )),
    result_json            TEXT CHECK (
                               result_json IS NULL
                               OR (
                                   length(result_json) <= 1048576
                                   AND json_valid(result_json)
                                   AND json_type(result_json) = 'object'
                               )
                           ),
    probed_at_ms           INTEGER NOT NULL CHECK (probed_at_ms >= 0),
    CHECK (
        (status = 'confirmed' AND result_json IS NOT NULL)
        OR (status <> 'confirmed' AND result_json IS NULL)
    )
) STRICT;

PRAGMA user_version = 11;
