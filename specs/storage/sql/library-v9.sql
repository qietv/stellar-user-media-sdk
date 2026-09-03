-- Playlist thumbnails are derived visual assets. Keep them separate from entity artwork so a
-- collection can be invalidated by its ordered membership without pretending it is a media entity.
CREATE TABLE collection_thumbnail (
    collection_id INTEGER PRIMARY KEY
        REFERENCES media_collection(id) ON DELETE CASCADE,
    provider TEXT NOT NULL CHECK (provider <> ''),
    input_signature TEXT NOT NULL
        CHECK (length(input_signature) = 64 AND input_signature NOT GLOB '*[^0-9a-f]*'),
    sha256 TEXT NOT NULL
        CHECK (length(sha256) = 64 AND sha256 NOT GLOB '*[^0-9a-f]*'),
    local_relative_path TEXT NOT NULL CHECK (local_relative_path <> ''),
    mime_type TEXT NOT NULL CHECK (mime_type IN ('image/jpeg', 'image/png')),
    width INTEGER NOT NULL CHECK (width > 0),
    height INTEGER NOT NULL CHECK (height > 0),
    updated_at_ms INTEGER NOT NULL CHECK (updated_at_ms >= 0)
) STRICT;

PRAGMA user_version = 9;
