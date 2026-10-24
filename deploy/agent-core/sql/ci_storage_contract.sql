-- Postgres 16 contract for the portable Docker/Podman development fixture.
-- This test data must NEVER be applied to a real production database.
\set ON_ERROR_STOP on

INSERT INTO agent_ops.execution_attempts (
  effect_id, intent_event_id, chapter_id, tenant_id, project_id, run_id,
  task_id, task_version, task_source_event_id, definition_digest,
  execution_profile_id, execution_profile_digest, max_duration_ms,
  max_output_bytes, descriptor_digest
) VALUES (
  'agent-run:signed-ci', 'signed-ci', 'ci-chapter', 'ci-tenant',
  'ci-project', 'ci-run', 'ci-task', 3, 'ci-source',
  decode(repeat('aa', 32), 'hex'), 'approved-profile',
  decode(repeat('bb', 32), 'hex'), 30000, 4096,
  decode(repeat('cc', 32), 'hex')
);

-- One host can claim only the expected pending revision; this represents
-- the SQL transaction boundary a real coordinator must use.
DO $contract$
DECLARE
  changed integer;
BEGIN
  UPDATE agent_ops.execution_attempts
     SET phase = 'leased',
         attempt_epoch = attempt_epoch + 1,
         attempts = attempts + 1,
         lease_owner = 'worker-ci',
         lease_token_sha256 = decode(repeat('dd', 32), 'hex'),
         lease_expires_at = clock_timestamp() + interval '10 minutes',
         row_version = row_version + 1,
         updated_at = clock_timestamp()
   WHERE effect_id = 'agent-run:signed-ci'
     AND phase = 'pending' AND row_version = 1;

  GET DIAGNOSTICS changed = ROW_COUNT;
  IF changed <> 1 THEN
    RAISE EXCEPTION 'first CAS claim was not admitted';
  END IF;

  UPDATE agent_ops.execution_attempts
     SET attempts = attempts + 1
   WHERE effect_id = 'agent-run:signed-ci'
     AND phase = 'pending' AND row_version = 1;

  GET DIAGNOSTICS changed = ROW_COUNT;
  IF changed <> 0 THEN
    RAISE EXCEPTION 'stale CAS claim was not rejected';
  END IF;

  IF NOT EXISTS (
      SELECT 1
        FROM agent_ops.execution_attempts
       WHERE effect_id = 'agent-run:signed-ci'
         AND phase = 'leased' AND row_version = 2
         AND attempt_epoch = 1 AND attempts = 1
         AND lease_expires_at IS NOT NULL
  ) THEN
    RAISE EXCEPTION 'persisted claim shape did not match';
  END IF;
END
$contract$;

-- A volume persistence probe is re-read after container recreation in CI.
CREATE TABLE IF NOT EXISTS agent_ops.volume_probe (id text PRIMARY KEY);
INSERT INTO agent_ops.volume_probe (id) VALUES ('volume-ok')
ON CONFLICT (id) DO NOTHING;
