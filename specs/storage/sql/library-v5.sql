-- Workers claim only a small ready batch. Preserve queue priority and insertion order
-- so SQLite can stop at LIMIT instead of sorting an entire source by media path.
CREATE INDEX idx_scan_queue_claim_order
    ON scan_queue(stage, priority DESC, id)
    WHERE state IN ('queued', 'running', 'retry', 'failed');

PRAGMA user_version = 5;
