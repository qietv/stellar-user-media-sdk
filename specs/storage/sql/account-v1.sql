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
                            'e2ee_synced', 'device_local', 'server_managed', 'none'
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

CREATE TABLE credential_envelope (
    credential_uid      TEXT PRIMARY KEY,
    account_uid         TEXT NOT NULL,
    source_uid          TEXT NOT NULL,
    kind                TEXT NOT NULL,
    algorithm           TEXT NOT NULL CHECK (algorithm = 'aes_256_gcm'),
    key_version         INTEGER NOT NULL CHECK (key_version > 0),
    nonce_b64           TEXT NOT NULL,
    ciphertext_b64      TEXT NOT NULL,
    aad_version         INTEGER NOT NULL DEFAULT 1 CHECK (aad_version = 1),
    revision            INTEGER NOT NULL CHECK (revision >= 0),
    base_revision       INTEGER NOT NULL CHECK (base_revision >= 0),
    updated_at_ms       INTEGER NOT NULL,
    deleted_at_ms       INTEGER,
    schema_version      INTEGER NOT NULL DEFAULT 1 CHECK (schema_version = 1)
);

CREATE INDEX idx_credential_envelope_account
    ON credential_envelope(account_uid, deleted_at_ms, credential_uid);
CREATE INDEX idx_credential_envelope_source
    ON credential_envelope(source_uid, deleted_at_ms);

CREATE TABLE sync_conflict (
    id                  INTEGER PRIMARY KEY,
    conflict_uid        TEXT NOT NULL UNIQUE,
    account_uid         TEXT NOT NULL,
    entity_type         TEXT NOT NULL CHECK (entity_type IN ('media_source_config', 'credential_envelope')),
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
    entity_type         TEXT NOT NULL CHECK (entity_type IN ('media_source_config', 'credential_envelope')),
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
