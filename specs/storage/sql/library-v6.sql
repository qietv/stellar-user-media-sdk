-- One transaction-scoped counter lets read APIs validate opaque cursors without
-- rescanning and hashing every user-visible library row.
CREATE TABLE library_revision (
    id                  INTEGER PRIMARY KEY CHECK (id = 1),
    revision            INTEGER NOT NULL CHECK (revision >= 0)
) WITHOUT ROWID;

INSERT INTO library_revision(id, revision) VALUES (1, 0);

PRAGMA user_version = 6;
