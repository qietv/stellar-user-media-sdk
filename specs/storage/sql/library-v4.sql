-- Give every published file fact a material revision. Observation-only scans do
-- not change this value; any change that can alter metadata worker output does.
ALTER TABLE media_file
ADD COLUMN material_revision INTEGER NOT NULL DEFAULT 1
    CHECK (material_revision > 0);

-- Queue work captures the material revision it was created for. Claim tokens
-- make worker ownership explicit and allow completion/retry to use compare-and-
-- set semantics instead of updating every task for a path.
ALTER TABLE scan_queue
ADD COLUMN input_revision INTEGER NOT NULL DEFAULT 1
    CHECK (input_revision > 0);

ALTER TABLE scan_queue
ADD COLUMN claimed_by TEXT;

ALTER TABLE scan_queue
ADD COLUMN claim_token TEXT;

ALTER TABLE scan_queue
ADD COLUMN heartbeat_at_ms INTEGER;

-- Older SDKs could leave a task in running state with only lease_until_ms. Such
-- a task has no verifiable owner, so make it immediately reclaimable.
UPDATE scan_queue
SET state = 'retry',
    lease_until_ms = NULL,
    claimed_by = NULL,
    claim_token = NULL,
    heartbeat_at_ms = NULL
WHERE state = 'running';

UPDATE scan_queue
SET input_revision = COALESCE(
    (SELECT material_revision FROM media_file WHERE media_file.id = scan_queue.media_file_id),
    1
);

CREATE UNIQUE INDEX uq_scan_queue_claim_token
    ON scan_queue(claim_token)
    WHERE claim_token IS NOT NULL;

CREATE INDEX idx_scan_queue_stage_dispatch
    ON scan_queue(stage, state, next_attempt_at_ms, lease_until_ms, priority DESC, id);

PRAGMA user_version = 4;
