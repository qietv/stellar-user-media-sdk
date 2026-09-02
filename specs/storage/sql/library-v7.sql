-- Terminal failures must leave the hot claim-order index so a large set of
-- permanent provider misses cannot slow every later small-batch claim.
DROP INDEX idx_scan_queue_claim_order;

CREATE INDEX idx_scan_queue_claim_order
    ON scan_queue(stage, priority DESC, id)
    WHERE state IN ('queued', 'running', 'retry');

PRAGMA user_version = 7;
