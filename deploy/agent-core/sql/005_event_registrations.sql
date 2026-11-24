-- Operational effects only. EventStore owns persistent delivery/checkpoints.
BEGIN;
CREATE TABLE IF NOT EXISTS agent_ops.event_effect_registrations (
  subscription_name text NOT NULL CHECK (length(subscription_name) BETWEEN 1 AND 128),
  event_id text NOT NULL CHECK (length(event_id) BETWEEN 1 AND 128),
  global_seq bigint NOT NULL CHECK (global_seq>0),
  event_hash bytea NOT NULL CHECK (octet_length(event_hash)=32),
  effect_id text,
  chapter_id text,
  tenant_id text,
  project_id text,
  PRIMARY KEY (subscription_name,event_id),
  UNIQUE (subscription_name,global_seq),
  UNIQUE (subscription_name,effect_id),
  CHECK ((effect_id IS NULL AND chapter_id IS NULL AND tenant_id IS NULL AND project_id IS NULL)
    OR (effect_id IS NOT NULL AND effect_id='agent-event:' || event_id
        AND chapter_id IS NOT NULL AND length(chapter_id) BETWEEN 1 AND 128
        AND ((tenant_id IS NULL AND project_id IS NULL) OR
             (tenant_id IS NOT NULL AND project_id IS NOT NULL
              AND length(tenant_id) BETWEEN 1 AND 128 AND length(project_id) BETWEEN 1 AND 128))))
);
REVOKE ALL ON agent_ops.event_effect_registrations FROM PUBLIC;
COMMENT ON TABLE agent_ops.event_effect_registrations IS
  'Idempotent discovery effects and no-op receipts; EventStore subscriptions alone own delivery checkpoints.';
-- The trusted host needs SELECT/INSERT only, no UPDATE/DELETE. This does not
-- grant anything to production roles or modify EventStore's subscriptions.
COMMIT;
