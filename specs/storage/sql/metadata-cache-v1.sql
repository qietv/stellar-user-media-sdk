PRAGMA application_id = 1296253251;
PRAGMA user_version = 1;

CREATE TABLE provider_response_cache (
    request_key         TEXT PRIMARY KEY,
    provider            TEXT NOT NULL,
    endpoint            TEXT NOT NULL,
    request_fingerprint TEXT NOT NULL,
    locale              TEXT NOT NULL DEFAULT 'und',
    http_status         INTEGER NOT NULL,
    etag                TEXT,
    last_modified       TEXT,
    response_json       TEXT,
    fetched_at_ms       INTEGER NOT NULL,
    expires_at_ms       INTEGER NOT NULL,
    error_count         INTEGER NOT NULL DEFAULT 0
);

CREATE INDEX idx_provider_cache_expiry
    ON provider_response_cache(expires_at_ms);

CREATE TABLE match_candidate_cache (
    file_uid            TEXT NOT NULL,
    provider            TEXT NOT NULL,
    entity_kind         TEXT NOT NULL,
    provider_id         TEXT NOT NULL,
    candidate_title     TEXT NOT NULL,
    candidate_year      INTEGER,
    season_number       INTEGER,
    episode_number      INTEGER,
    score               REAL NOT NULL,
    rank                INTEGER NOT NULL,
    raw_fragment_json   TEXT,
    created_at_ms       INTEGER NOT NULL,
    PRIMARY KEY(file_uid, provider, entity_kind, provider_id)
);

CREATE INDEX idx_match_candidate_rank
    ON match_candidate_cache(file_uid, score DESC, rank);

CREATE TABLE artwork_cache_file (
    sha256              TEXT PRIMARY KEY,
    relative_path       TEXT NOT NULL UNIQUE,
    mime_type           TEXT NOT NULL,
    width               INTEGER,
    height              INTEGER,
    size_bytes          INTEGER NOT NULL,
    last_access_at_ms   INTEGER NOT NULL
);
