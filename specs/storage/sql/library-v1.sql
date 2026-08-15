PRAGMA application_id = 1296845122;
PRAGMA user_version = 1;

CREATE TABLE schema_migration (
    version             INTEGER PRIMARY KEY,
    applied_at_ms       INTEGER NOT NULL,
    checksum            TEXT NOT NULL
);

CREATE TABLE library_source (
    id                  INTEGER PRIMARY KEY,
    uid                 TEXT NOT NULL UNIQUE,
    kind                TEXT NOT NULL CHECK (kind IN (
                            'local_folder', 'device_media', 'smb', 'nfs',
                            'webdav', 'ftp', 'cloud_drive', 'plex', 'emby', 'jellyfin'
                        )),
    display_name        TEXT NOT NULL,
    root_uri            TEXT NOT NULL,
    access_handle       BLOB,
    credential_ref      TEXT,
    capabilities_json   TEXT,
    scan_policy         TEXT NOT NULL DEFAULT 'incremental'
                        CHECK (scan_policy IN ('manual', 'incremental', 'scheduled')),
    enabled             INTEGER NOT NULL DEFAULT 1 CHECK (enabled IN (0, 1)),
    created_at_ms       INTEGER NOT NULL,
    updated_at_ms       INTEGER NOT NULL,
    last_scan_at_ms     INTEGER,
    deleted_at_ms       INTEGER
);

CREATE TABLE scan_run (
    id                  INTEGER PRIMARY KEY,
    uid                 TEXT NOT NULL UNIQUE,
    source_id           INTEGER NOT NULL REFERENCES library_source(id) ON DELETE RESTRICT,
    mode                TEXT NOT NULL CHECK (mode IN ('full', 'incremental', 'repair')),
    state               TEXT NOT NULL CHECK (state IN (
                            'queued', 'enumerating', 'processing',
                            'finalizing', 'completed', 'cancelled', 'failed'
                        )),
    checkpoint_json     TEXT NOT NULL,
    cursor_in           TEXT,
    cursor_out          TEXT,
    coverage_json       TEXT,
    reconcile_missing   INTEGER NOT NULL DEFAULT 0 CHECK (reconcile_missing IN (0, 1)),
    started_at_ms       INTEGER,
    finished_at_ms      INTEGER,
    discovered_count    INTEGER NOT NULL DEFAULT 0,
    changed_count       INTEGER NOT NULL DEFAULT 0,
    ready_count         INTEGER NOT NULL DEFAULT 0,
    error_count         INTEGER NOT NULL DEFAULT 0,
    error_code          TEXT,
    error_summary       TEXT
);

CREATE INDEX idx_scan_run_source_time
    ON scan_run(source_id, started_at_ms DESC);

CREATE TABLE media_file (
    id                  INTEGER PRIMARY KEY,
    uid                 TEXT NOT NULL UNIQUE,
    source_id           INTEGER NOT NULL REFERENCES library_source(id) ON DELETE RESTRICT,
    stable_key          TEXT NOT NULL,
    stable_id           TEXT,
    parent_stable_key   TEXT,
    relative_path       TEXT NOT NULL,
    path_compare_key    TEXT NOT NULL,
    display_name        TEXT NOT NULL,
    extension           TEXT,
    mime_type           TEXT,
    size_bytes          INTEGER,
    modified_at_ms      INTEGER,
    created_at_ms       INTEGER,
    etag                TEXT,
    quick_hash          TEXT,
    full_hash           TEXT,
    availability        TEXT NOT NULL DEFAULT 'present'
                        CHECK (availability IN (
                            'present', 'offline', 'missing', 'excluded', 'deleted'
                        )),
    last_seen_run_id    INTEGER REFERENCES scan_run(id) ON DELETE SET NULL,
    missing_since_ms    INTEGER,
    missing_scan_count  INTEGER NOT NULL DEFAULT 0,
    parser_version      INTEGER NOT NULL DEFAULT 0,
    probe_version       INTEGER NOT NULL DEFAULT 0,
    indexed_at_ms       INTEGER,
    deleted_at_ms       INTEGER,
    updated_at_ms       INTEGER NOT NULL,
    UNIQUE(source_id, stable_key)
);

CREATE INDEX idx_media_file_source_path
    ON media_file(source_id, path_compare_key);
CREATE INDEX idx_media_file_source_availability
    ON media_file(source_id, availability);
CREATE INDEX idx_media_file_last_seen
    ON media_file(source_id, last_seen_run_id);
CREATE INDEX idx_media_file_quick_hash
    ON media_file(quick_hash) WHERE quick_hash IS NOT NULL;

CREATE TABLE sidecar (
    id                  INTEGER PRIMARY KEY,
    uid                 TEXT NOT NULL UNIQUE,
    media_file_id       INTEGER NOT NULL REFERENCES media_file(id) ON DELETE CASCADE,
    kind                TEXT NOT NULL CHECK (kind IN (
                            'nfo', 'metadata_json', 'poster', 'backdrop',
                            'logo', 'subtitle', 'chapters', 'other'
                        )),
    relative_path       TEXT NOT NULL,
    language            TEXT NOT NULL DEFAULT 'und',
    forced              INTEGER NOT NULL DEFAULT 0 CHECK (forced IN (0, 1)),
    modified_at_ms      INTEGER,
    sha256              TEXT,
    parsed_json         TEXT,
    UNIQUE(media_file_id, relative_path)
);

CREATE TABLE parse_result (
    media_file_id       INTEGER PRIMARY KEY REFERENCES media_file(id) ON DELETE CASCADE,
    media_kind          TEXT NOT NULL CHECK (media_kind IN (
                            'movie', 'episode', 'extra', 'unknown'
                        )),
    clean_title         TEXT,
    sort_title          TEXT,
    hint_year           INTEGER,
    season_number       INTEGER,
    episode_start       INTEGER,
    episode_end         INTEGER,
    edition             TEXT,
    release_group       TEXT,
    language_hint       TEXT,
    provider_hints_json TEXT,
    raw_tokens_json     TEXT,
    confidence          REAL NOT NULL DEFAULT 0.0,
    parser_version      INTEGER NOT NULL,
    updated_at_ms       INTEGER NOT NULL,
    CHECK (episode_end IS NULL OR episode_start IS NOT NULL),
    CHECK (episode_end IS NULL OR episode_end >= episode_start)
);

CREATE TABLE technical_summary (
    media_file_id       INTEGER PRIMARY KEY REFERENCES media_file(id) ON DELETE CASCADE,
    container           TEXT,
    duration_ms         INTEGER,
    overall_bitrate     INTEGER,
    video_codec         TEXT,
    width               INTEGER,
    height              INTEGER,
    frame_rate          REAL,
    hdr_profile         TEXT,
    audio_codec         TEXT,
    audio_channels      REAL,
    embedded_cover      INTEGER NOT NULL DEFAULT 0 CHECK (embedded_cover IN (0, 1)),
    probe_provider      TEXT NOT NULL,
    probe_version       INTEGER NOT NULL,
    probed_at_ms        INTEGER NOT NULL,
    extra_json          TEXT
);

CREATE TABLE media_stream (
    id                  INTEGER PRIMARY KEY,
    media_file_id       INTEGER NOT NULL REFERENCES media_file(id) ON DELETE CASCADE,
    stream_index        INTEGER NOT NULL,
    kind                TEXT NOT NULL CHECK (kind IN ('video', 'audio', 'subtitle', 'attachment')),
    codec               TEXT,
    language            TEXT NOT NULL DEFAULT 'und',
    title               TEXT,
    bit_rate            INTEGER,
    width               INTEGER,
    height              INTEGER,
    frame_rate          REAL,
    hdr_profile         TEXT,
    channel_count       REAL,
    channel_layout      TEXT,
    sample_rate         INTEGER,
    is_default          INTEGER NOT NULL DEFAULT 0 CHECK (is_default IN (0, 1)),
    is_forced           INTEGER NOT NULL DEFAULT 0 CHECK (is_forced IN (0, 1)),
    extra_json          TEXT,
    UNIQUE(media_file_id, stream_index)
);

CREATE INDEX idx_media_stream_file_kind
    ON media_stream(media_file_id, kind);

CREATE TABLE media_entity (
    id                  INTEGER PRIMARY KEY,
    uid                 TEXT NOT NULL UNIQUE,
    kind                TEXT NOT NULL CHECK (kind IN (
                            'movie', 'series', 'season', 'episode', 'extra'
                        )),
    parent_id           INTEGER REFERENCES media_entity(id) ON DELETE RESTRICT,
    canonical_title     TEXT NOT NULL,
    original_title      TEXT,
    sort_title          TEXT,
    original_language   TEXT NOT NULL DEFAULT 'und',
    year                INTEGER,
    season_number       INTEGER,
    episode_number      INTEGER,
    episode_end_number  INTEGER,
    release_date        TEXT,
    runtime_ms          INTEGER,
    status              TEXT NOT NULL DEFAULT 'active'
                        CHECK (status IN ('active', 'unmatched', 'obsolete', 'deleted')),
    metadata_state      TEXT NOT NULL DEFAULT 'partial'
                        CHECK (metadata_state IN ('none', 'partial', 'complete', 'manual')),
    locked_fields_json  TEXT,
    created_at_ms       INTEGER NOT NULL,
    updated_at_ms       INTEGER NOT NULL,
    deleted_at_ms       INTEGER,
    CHECK ((kind IN ('movie', 'series') AND parent_id IS NULL)
        OR (kind IN ('season', 'episode', 'extra') AND parent_id IS NOT NULL))
);

CREATE UNIQUE INDEX uq_media_season
    ON media_entity(parent_id, season_number)
    WHERE kind = 'season';
CREATE UNIQUE INDEX uq_media_episode
    ON media_entity(parent_id, episode_number)
    WHERE kind = 'episode';
CREATE INDEX idx_media_entity_kind_sort
    ON media_entity(kind, sort_title, canonical_title);
CREATE INDEX idx_media_entity_parent
    ON media_entity(parent_id);

CREATE TABLE file_binding (
    media_file_id       INTEGER NOT NULL REFERENCES media_file(id) ON DELETE CASCADE,
    entity_id           INTEGER NOT NULL REFERENCES media_entity(id) ON DELETE RESTRICT,
    binding_role        TEXT NOT NULL DEFAULT 'primary'
                        CHECK (binding_role IN ('primary', 'contained', 'version', 'extra')),
    match_method        TEXT NOT NULL CHECK (match_method IN (
                            'manual', 'sidecar_id', 'filename_id', 'provider_search',
                            'media_server', 'inherited'
                        )),
    confidence          REAL NOT NULL,
    matched_query       TEXT,
    locked              INTEGER NOT NULL DEFAULT 0 CHECK (locked IN (0, 1)),
    decided_at_ms       INTEGER NOT NULL,
    PRIMARY KEY(media_file_id, entity_id)
);

CREATE UNIQUE INDEX uq_file_primary_binding
    ON file_binding(media_file_id)
    WHERE binding_role = 'primary';
CREATE INDEX idx_file_binding_entity
    ON file_binding(entity_id);

CREATE TABLE external_id (
    entity_id           INTEGER NOT NULL REFERENCES media_entity(id) ON DELETE CASCADE,
    provider            TEXT NOT NULL,
    namespace           TEXT NOT NULL,
    external_value      TEXT NOT NULL,
    is_primary          INTEGER NOT NULL DEFAULT 0 CHECK (is_primary IN (0, 1)),
    updated_at_ms       INTEGER NOT NULL,
    PRIMARY KEY(entity_id, provider, namespace),
    UNIQUE(provider, namespace, external_value)
);

CREATE INDEX idx_external_id_lookup
    ON external_id(provider, namespace, external_value);

CREATE TABLE localized_metadata (
    entity_id           INTEGER NOT NULL REFERENCES media_entity(id) ON DELETE CASCADE,
    locale              TEXT NOT NULL,
    title               TEXT NOT NULL,
    sort_title          TEXT,
    overview            TEXT,
    tagline             TEXT,
    content_rating      TEXT,
    provider            TEXT NOT NULL,
    provider_updated_at_ms INTEGER,
    materialized_at_ms  INTEGER NOT NULL,
    PRIMARY KEY(entity_id, locale)
);

CREATE TABLE genre (
    id                  INTEGER PRIMARY KEY,
    uid                 TEXT NOT NULL UNIQUE,
    provider            TEXT NOT NULL,
    provider_key        TEXT NOT NULL,
    UNIQUE(provider, provider_key)
);

CREATE TABLE genre_name (
    genre_id            INTEGER NOT NULL REFERENCES genre(id) ON DELETE CASCADE,
    locale              TEXT NOT NULL,
    name                TEXT NOT NULL,
    PRIMARY KEY(genre_id, locale)
);

CREATE TABLE entity_genre (
    entity_id           INTEGER NOT NULL REFERENCES media_entity(id) ON DELETE CASCADE,
    genre_id            INTEGER NOT NULL REFERENCES genre(id) ON DELETE CASCADE,
    position            INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY(entity_id, genre_id)
);

CREATE INDEX idx_entity_genre_genre
    ON entity_genre(genre_id, entity_id);

CREATE TABLE person (
    id                  INTEGER PRIMARY KEY,
    uid                 TEXT NOT NULL UNIQUE,
    display_name        TEXT NOT NULL,
    sort_name           TEXT,
    profile_url         TEXT
);

CREATE TABLE credit (
    entity_id           INTEGER NOT NULL REFERENCES media_entity(id) ON DELETE CASCADE,
    person_id           INTEGER NOT NULL REFERENCES person(id) ON DELETE CASCADE,
    credit_kind         TEXT NOT NULL CHECK (credit_kind IN ('cast', 'director', 'writer', 'crew')),
    role_name           TEXT NOT NULL DEFAULT '',
    department          TEXT,
    position            INTEGER NOT NULL DEFAULT 0,
    provider_credit_id  TEXT,
    PRIMARY KEY(entity_id, person_id, credit_kind, role_name)
);

CREATE INDEX idx_credit_person
    ON credit(person_id, entity_id);

CREATE TABLE artwork (
    id                  INTEGER PRIMARY KEY,
    uid                 TEXT NOT NULL UNIQUE,
    entity_id           INTEGER NOT NULL REFERENCES media_entity(id) ON DELETE CASCADE,
    kind                TEXT NOT NULL CHECK (kind IN (
                            'poster', 'backdrop', 'logo', 'still', 'banner', 'thumbnail'
                        )),
    locale              TEXT NOT NULL DEFAULT 'und',
    provider            TEXT NOT NULL,
    remote_url          TEXT,
    sha256              TEXT,
    local_relative_path TEXT,
    mime_type           TEXT,
    width               INTEGER,
    height              INTEGER,
    score               REAL,
    is_selected         INTEGER NOT NULL DEFAULT 0 CHECK (is_selected IN (0, 1)),
    fetched_at_ms       INTEGER,
    updated_at_ms       INTEGER NOT NULL
);

CREATE UNIQUE INDEX uq_artwork_remote
    ON artwork(entity_id, kind, provider, remote_url)
    WHERE remote_url IS NOT NULL;
CREATE UNIQUE INDEX uq_artwork_selected
    ON artwork(entity_id, kind, locale)
    WHERE is_selected = 1;
CREATE INDEX idx_artwork_sha256
    ON artwork(sha256) WHERE sha256 IS NOT NULL;

CREATE TABLE playback_profile (
    id                  INTEGER PRIMARY KEY,
    uid                 TEXT NOT NULL UNIQUE,
    display_name        TEXT NOT NULL,
    is_default          INTEGER NOT NULL DEFAULT 0 CHECK (is_default IN (0, 1)),
    created_at_ms       INTEGER NOT NULL,
    updated_at_ms       INTEGER NOT NULL
);

CREATE UNIQUE INDEX uq_default_profile
    ON playback_profile(is_default)
    WHERE is_default = 1;

CREATE TABLE playback_state (
    profile_id          INTEGER NOT NULL REFERENCES playback_profile(id) ON DELETE CASCADE,
    entity_id           INTEGER NOT NULL REFERENCES media_entity(id) ON DELETE RESTRICT,
    media_file_id       INTEGER REFERENCES media_file(id) ON DELETE SET NULL,
    position_ms         INTEGER NOT NULL DEFAULT 0,
    duration_ms         INTEGER,
    completed           INTEGER NOT NULL DEFAULT 0 CHECK (completed IN (0, 1)),
    play_count          INTEGER NOT NULL DEFAULT 0,
    last_played_at_ms   INTEGER,
    updated_at_ms       INTEGER NOT NULL,
    revision            INTEGER NOT NULL DEFAULT 1,
    PRIMARY KEY(profile_id, entity_id)
);

CREATE INDEX idx_playback_state_recent
    ON playback_state(profile_id, last_played_at_ms DESC)
    WHERE last_played_at_ms IS NOT NULL;

CREATE TABLE playback_marker (
    entity_id           INTEGER NOT NULL REFERENCES media_entity(id) ON DELETE CASCADE,
    kind                TEXT NOT NULL CHECK (kind IN (
                            'intro', 'recap', 'credits', 'outro', 'commercial', 'chapter'
                        )),
    ordinal             INTEGER NOT NULL DEFAULT 0,
    start_ms            INTEGER NOT NULL,
    end_ms              INTEGER,
    provider            TEXT NOT NULL,
    confidence          REAL,
    submissions         INTEGER,
    updated_at_ms       INTEGER NOT NULL,
    PRIMARY KEY(entity_id, kind, ordinal, provider),
    CHECK (end_ms IS NULL OR end_ms >= start_ms)
);

CREATE TABLE media_collection (
    id                  INTEGER PRIMARY KEY,
    uid                 TEXT NOT NULL UNIQUE,
    kind                TEXT NOT NULL CHECK (kind IN ('manual', 'provider', 'smart')),
    title               TEXT NOT NULL,
    sort_title          TEXT,
    rule_json           TEXT,
    provider            TEXT,
    provider_key        TEXT,
    created_at_ms       INTEGER NOT NULL,
    updated_at_ms       INTEGER NOT NULL,
    deleted_at_ms       INTEGER
);

CREATE TABLE collection_item (
    collection_id       INTEGER NOT NULL REFERENCES media_collection(id) ON DELETE CASCADE,
    entity_id           INTEGER NOT NULL REFERENCES media_entity(id) ON DELETE RESTRICT,
    position            INTEGER NOT NULL DEFAULT 0,
    added_at_ms         INTEGER NOT NULL,
    PRIMARY KEY(collection_id, entity_id)
);

CREATE INDEX idx_collection_item_entity
    ON collection_item(entity_id);

CREATE TABLE scan_queue (
    id                  INTEGER PRIMARY KEY,
    run_id              INTEGER NOT NULL REFERENCES scan_run(id) ON DELETE CASCADE,
    media_file_id       INTEGER NOT NULL REFERENCES media_file(id) ON DELETE CASCADE,
    stage               TEXT NOT NULL CHECK (stage IN (
                            'parse', 'probe', 'local_metadata', 'match',
                            'materialize', 'artwork', 'search_index'
                        )),
    state               TEXT NOT NULL DEFAULT 'queued'
                        CHECK (state IN ('queued', 'running', 'retry', 'done', 'failed')),
    priority            INTEGER NOT NULL DEFAULT 0,
    attempts            INTEGER NOT NULL DEFAULT 0,
    next_attempt_at_ms  INTEGER,
    lease_until_ms      INTEGER,
    error_code          TEXT,
    error_message       TEXT,
    updated_at_ms       INTEGER NOT NULL,
    UNIQUE(run_id, media_file_id, stage)
);

CREATE INDEX idx_scan_queue_dispatch
    ON scan_queue(state, next_attempt_at_ms, priority DESC, id);

CREATE TABLE search_document (
    entity_id           INTEGER PRIMARY KEY REFERENCES media_entity(id) ON DELETE CASCADE,
    title               TEXT NOT NULL,
    aliases             TEXT NOT NULL DEFAULT '',
    people              TEXT NOT NULL DEFAULT '',
    genres              TEXT NOT NULL DEFAULT '',
    romanized           TEXT NOT NULL DEFAULT '',
    updated_at_ms       INTEGER NOT NULL
);

CREATE TABLE change_log (
    seq                 INTEGER PRIMARY KEY AUTOINCREMENT,
    event_uid           TEXT NOT NULL UNIQUE,
    entity_type         TEXT NOT NULL,
    entity_uid          TEXT NOT NULL,
    operation           TEXT NOT NULL CHECK (operation IN ('upsert', 'delete')),
    payload_json        TEXT,
    device_uid          TEXT NOT NULL,
    modified_at_ms      INTEGER NOT NULL,
    uploaded_at_ms      INTEGER,
    retry_count         INTEGER NOT NULL DEFAULT 0
);

CREATE INDEX idx_change_log_pending
    ON change_log(uploaded_at_ms, seq);

CREATE TABLE sync_cursor (
    backend             TEXT NOT NULL,
    scope               TEXT NOT NULL,
    cursor_blob         BLOB,
    updated_at_ms       INTEGER NOT NULL,
    PRIMARY KEY(backend, scope)
);
