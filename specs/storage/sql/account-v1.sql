PRAGMA application_id = 1094927188;
PRAGMA user_version = 1;

CREATE TABLE schema_migration (
    version             INTEGER PRIMARY KEY,
    applied_at_ms       INTEGER NOT NULL,
    checksum            TEXT NOT NULL
);

CREATE TABLE media_source_config (
    uid                 TEXT PRIMARY KEY,
    account_uid         TEXT NOT NULL,
    kind                TEXT NOT NULL CHECK (kind IN (
                            'local_folder', 'device_media', 'smb', 'nfs',
                            'webdav', 'ftp', 'cloud_drive', 'plex', 'emby', 'jellyfin'
                        )),
    display_name        TEXT NOT NULL,
    endpoint_json       TEXT NOT NULL,
    root_path           TEXT NOT NULL,
    included_paths_json TEXT NOT NULL,
    excluded_paths_json TEXT NOT NULL,
    scan_policy_json    TEXT NOT NULL,
    metadata_policy_json TEXT NOT NULL,
    connection_mode     TEXT NOT NULL
                        CHECK (connection_mode IN ('direct', 'relay', 'automatic')),
    credential_mode     TEXT NOT NULL CHECK (credential_mode IN (
                            'synced', 'device_local', 'server_managed', 'none'
                        )),
    credential_uid      TEXT,
    capabilities_json   TEXT NOT NULL,
    revision            INTEGER NOT NULL CHECK (revision >= 0),
    base_revision       INTEGER NOT NULL CHECK (base_revision >= 0),
    updated_at_ms       INTEGER NOT NULL,
    deleted_at_ms       INTEGER,
    schema_version      INTEGER NOT NULL DEFAULT 1 CHECK (schema_version = 1)
);

CREATE INDEX idx_media_source_config_account
    ON media_source_config(account_uid, deleted_at_ms, uid);
CREATE INDEX idx_media_source_config_credential
    ON media_source_config(credential_uid)
    WHERE credential_uid IS NOT NULL;

CREATE TABLE credential_record (
    credential_uid      TEXT PRIMARY KEY,
    account_uid         TEXT NOT NULL,
    source_uid          TEXT NOT NULL,
    kind                TEXT NOT NULL,
    protection_mode     TEXT NOT NULL CHECK (protection_mode IN (
                            'plaintext', 'server_encrypted', 'end_to_end_encrypted'
                        )),
    payload_json        TEXT CHECK (payload_json IS NULL OR length(payload_json) <= 65536),
    algorithm           TEXT,
    key_version         INTEGER CHECK (key_version IS NULL OR key_version > 0),
    nonce_b64           TEXT,
    protected_payload_b64 TEXT,
    aad_version         INTEGER CHECK (aad_version IS NULL OR aad_version > 0),
    revision            INTEGER NOT NULL CHECK (revision >= 0),
    base_revision       INTEGER NOT NULL CHECK (base_revision >= 0),
    updated_at_ms       INTEGER NOT NULL,
    deleted_at_ms       INTEGER,
    schema_version      INTEGER NOT NULL DEFAULT 1 CHECK (schema_version = 1),
    CHECK (
        (protection_mode = 'plaintext'
            AND (payload_json IS NOT NULL OR deleted_at_ms IS NOT NULL)
            AND algorithm IS NULL
            AND key_version IS NULL
            AND nonce_b64 IS NULL
            AND protected_payload_b64 IS NULL
            AND aad_version IS NULL)
        OR
        (protection_mode IN ('server_encrypted', 'end_to_end_encrypted')
            AND payload_json IS NULL
            AND algorithm IS NOT NULL
            AND key_version IS NOT NULL
            AND nonce_b64 IS NOT NULL
            AND protected_payload_b64 IS NOT NULL
            AND aad_version IS NOT NULL)
    )
);

CREATE INDEX idx_credential_record_account
    ON credential_record(account_uid, deleted_at_ms, credential_uid);
CREATE INDEX idx_credential_record_source
    ON credential_record(source_uid, deleted_at_ms);

CREATE TABLE sync_conflict (
    id                  INTEGER PRIMARY KEY,
    conflict_uid        TEXT NOT NULL UNIQUE,
    account_uid         TEXT NOT NULL,
    entity_type         TEXT NOT NULL CHECK (entity_type IN ('media_source_config', 'credential_record')),
    entity_uid          TEXT NOT NULL,
    local_revision      INTEGER NOT NULL,
    remote_revision     INTEGER NOT NULL,
    local_payload_json  TEXT NOT NULL,
    remote_payload_json TEXT NOT NULL,
    created_at_ms       INTEGER NOT NULL,
    resolved_at_ms      INTEGER,
    resolution          TEXT CHECK (resolution IN ('local', 'remote', 'merged', 'deleted'))
);

CREATE INDEX idx_sync_conflict_unresolved
    ON sync_conflict(account_uid, resolved_at_ms, created_at_ms);

CREATE TABLE account_change_log (
    seq                 INTEGER PRIMARY KEY AUTOINCREMENT,
    operation_uid       TEXT NOT NULL UNIQUE,
    account_uid         TEXT NOT NULL,
    entity_type         TEXT NOT NULL CHECK (entity_type IN ('media_source_config', 'credential_record')),
    entity_uid          TEXT NOT NULL,
    base_revision       INTEGER NOT NULL CHECK (base_revision >= 0),
    operation           TEXT NOT NULL CHECK (operation IN ('upsert', 'delete')),
    payload_json        TEXT,
    modified_at_ms      INTEGER NOT NULL,
    uploaded_at_ms      INTEGER,
    retry_count         INTEGER NOT NULL DEFAULT 0,
    last_error_code     TEXT
);

CREATE INDEX idx_account_change_log_pending
    ON account_change_log(account_uid, uploaded_at_ms, seq);

CREATE TABLE account_sync_cursor (
    account_uid         TEXT NOT NULL,
    backend             TEXT NOT NULL,
    scope               TEXT NOT NULL,
    cursor_blob         BLOB,
    updated_at_ms       INTEGER NOT NULL,
    PRIMARY KEY(account_uid, backend, scope)
);
