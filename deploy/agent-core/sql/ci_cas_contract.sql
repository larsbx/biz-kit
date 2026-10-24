-- Staging database contract tests for transactional AgentCore CAS primitives.
-- Executed only against disposable CI PostgreSQL 16, not production.
\set ON_ERROR_STOP on

DO $contract$
DECLARE
  effect text := 'agent-run:signed-cas';
  token bytea := decode(repeat('e1', 32), 'hex');
  wrong_token bytea := decode(repeat('e2', 32), 'hex');
  candidate bytea := decode(repeat('a5', 32), 'hex');
  current_version bigint;
  current_epoch bigint;
  resulting_version bigint;
  found_rows integer;
BEGIN
  INSERT INTO agent_ops.execution_attempts (
    effect_id, intent_event_id, chapter_id, tenant_id, project_id, run_id,
    task_id, task_version, task_source_event_id, definition_digest,
    execution_profile_id, execution_profile_digest, max_duration_ms,
    max_output_bytes, descriptor_digest
  ) VALUES (
    effect, 'signed-cas', 'ci-chapter', 'ci-tenant',
    'ci-project', 'ci-run-cas', 'ci-task', 3, 'ci-source',
    decode(repeat('aa', 32), 'hex'), 'approved-profile',
    decode(repeat('bb', 32), 'hex'), 30000, 4096,
    decode(repeat('cc', 32), 'hex')
  );

  -- Registered state starts with a single reusable row/version.
  SELECT epoch, version INTO current_epoch, current_version
    FROM agent_ops.claim_attempt(effect, 1, 'worker-ci', token, 60000, 2);
  IF NOT FOUND OR current_epoch <> 1 OR current_version <> 2 THEN
    RAISE EXCEPTION 'claim did not create first fenced lease';
  END IF;

  -- Competing node with a stale version cannot claim.
  SELECT count(*) INTO found_rows
    FROM agent_ops.claim_attempt(effect, 1, 'worker-competitor', wrong_token, 60000, 2);
  IF found_rows <> 0 THEN
    RAISE EXCEPTION 'competing stale claim succeeded';
  END IF;

  -- A forged or old token cannot renew or record.
  SELECT count(*) INTO found_rows
    FROM agent_ops.renew_attempt(effect, current_version, current_epoch, wrong_token, 60000);
  IF found_rows <> 0 THEN
    RAISE EXCEPTION 'wrong-token renewal was admitted';
  END IF;

  SELECT version INTO current_version
    FROM agent_ops.renew_attempt(effect, current_version, current_epoch, token, 60000);
  IF NOT FOUND OR current_version <> 3 THEN
    RAISE EXCEPTION 'valid renewal did not advance version';
  END IF;

  SELECT version INTO current_version
    FROM agent_ops.attach_backend(effect, current_version, current_epoch, token, 'backend-1');
  IF NOT FOUND OR current_version <> 4 THEN
    RAISE EXCEPTION 'backend locator did not attach';
  END IF;

  SELECT count(*) INTO found_rows
    FROM agent_ops.attach_backend(effect, current_version, current_epoch, token, 'different-backend');
  IF found_rows <> 0 THEN
    RAISE EXCEPTION 'conflicting backend locator replaced original';
  END IF;

  SELECT count(*) INTO found_rows
    FROM agent_ops.record_candidate(effect, current_version, current_epoch, wrong_token, candidate);
  IF found_rows <> 0 THEN
    RAISE EXCEPTION 'wrong-token candidate was accepted';
  END IF;

  SELECT version INTO current_version
    FROM agent_ops.record_candidate(effect, current_version, current_epoch, token, candidate);
  IF NOT FOUND OR current_version <> 5 THEN
    RAISE EXCEPTION 'candidate was not recorded after authorized lease';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM agent_ops.execution_attempts
     WHERE effect_id = effect AND phase = 'candidate_ready'
       AND candidate_digest = candidate AND backend_ref = 'backend-1'
       AND lease_owner IS NULL AND lease_token_sha256 IS NULL
       AND lease_expires_at IS NULL AND row_version = 5
  ) THEN
    RAISE EXCEPTION 'candidate persisted incorrect operational state';
  END IF;

  SELECT count(*) INTO found_rows
    FROM agent_ops.claim_attempt(effect, 5, 'worker-retry', wrong_token, 60000, 2);
  IF found_rows <> 0 THEN
    RAISE EXCEPTION 'candidate-ready effect was relaunched';
  END IF;

  -- Cancellation invalidates the generation even after output exists.
  SELECT version INTO current_version FROM agent_ops.request_cancel(effect, 5);
  IF NOT FOUND OR current_version <> 6 THEN
    RAISE EXCEPTION 'signed-host cancellation did not fence candidate';
  END IF;

  SELECT count(*) INTO found_rows
    FROM agent_ops.confirm_cancel_preverified(effect, 5, 'termination-1');
  IF found_rows <> 0 THEN
    RAISE EXCEPTION 'stale confirmation overwrote cancellation';
  END IF;

  SELECT version INTO current_version
    FROM agent_ops.confirm_cancel_preverified(effect, 6, 'termination-1');
  IF NOT FOUND OR current_version <> 7 THEN
    RAISE EXCEPTION 'backend termination receipt did not close attempt';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM agent_ops.execution_attempts
     WHERE effect_id = effect AND phase = 'cancelled'
       AND cancellation_receipt_id = 'termination-1'
       AND row_version = 7
  ) THEN
    RAISE EXCEPTION 'cancelled state was not persisted';
  END IF;
END
$contract$;

DO $contract$
DECLARE
  effect text := 'agent-run:signed-expired';
  token bytea := decode(repeat('b4', 32), 'hex');
  version bigint;
  epoch bigint;
  found_rows integer;
BEGIN
  INSERT INTO agent_ops.execution_attempts (
    effect_id, intent_event_id, chapter_id, tenant_id, project_id, run_id,
    task_id, task_version, task_source_event_id, definition_digest,
    execution_profile_id, execution_profile_digest, max_duration_ms,
    max_output_bytes, descriptor_digest
  ) VALUES (
    effect, 'signed-expired', 'ci-chapter', 'ci-tenant',
    'ci-project', 'ci-run-expired', 'ci-task', 3, 'ci-source',
    decode(repeat('aa', 32), 'hex'), 'approved-profile',
    decode(repeat('bb', 32), 'hex'), 30000, 4096,
    decode(repeat('cc', 32), 'hex')
  );

  SELECT c.epoch, c.version INTO epoch, version
    FROM agent_ops.claim_attempt(effect, 1, 'worker-ci', token, 60000, 2) c;
  IF NOT FOUND OR epoch <> 1 THEN RAISE EXCEPTION 'expiry fixture not claimed'; END IF;

  -- Even if a trusted test uses a SQL clock override of the expiration,
  -- the expiry itself must never grant a new claim.
  UPDATE agent_ops.execution_attempts SET lease_expires_at = clock_timestamp() - interval '1 second'
   WHERE effect_id = effect;

  SELECT count(*) INTO found_rows
    FROM agent_ops.claim_attempt(effect, version, 'retry', token, 60000, 2);
  IF found_rows <> 0 THEN
    RAISE EXCEPTION 'timeout implicitly authorized retry';
  END IF;

  SELECT count(*) INTO found_rows
    FROM agent_ops.reconcile_absent_preverified(effect, version, 1, '../unverified');
  IF found_rows <> 0 THEN
    RAISE EXCEPTION 'malformed receipt accepted';
  END IF;

  -- Caller here is trusted CI; production callers must verify the backend
  -- absence evidence independently BEFORE invoking this function.
  SELECT r.version INTO version
    FROM agent_ops.reconcile_absent_preverified(effect, version, 1, 'verified-absence-1') r;
  IF NOT FOUND OR version <> 3 THEN
    RAISE EXCEPTION 'verified absence did not release expired lease';
  END IF;

  SELECT c.epoch, c.version INTO epoch, version
    FROM agent_ops.claim_attempt(effect, version, 'worker-retry', token, 60000, 2) c;
  IF NOT FOUND OR epoch <> 2 OR version <> 4 THEN
    RAISE EXCEPTION 'reconciled retry did not advance epoch';
  END IF;
END
$contract$;
