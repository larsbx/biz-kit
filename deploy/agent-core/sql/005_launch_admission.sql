-- Staging-only durable launch admission. This records a request decision,
-- not backend creation, execution, termination, or business authority.
--
-- CoopSubstrate.Log.admit_agent_launch must first lock the actual canonical
-- ledger stream row, check its sequence AND hash, and authorize the exact
-- signed run against that locked source. Lock order is ledger, then attempt.
-- This SECURITY INVOKER primitive cannot authenticate that caller precondition.
-- Grant it only to the trusted admission host, never an executor/public role.
-- No external call belongs inside this transaction.

BEGIN;

CREATE TABLE IF NOT EXISTS agent_ops.launch_admissions (
  effect_id text PRIMARY KEY REFERENCES agent_ops.execution_attempts(effect_id),
  admission_id text NOT NULL UNIQUE
    CHECK (admission_id ~ '^agent-admission:[0-9a-f]{64}$'),
  epoch bigint NOT NULL CHECK (epoch > 0),
  claim_version bigint NOT NULL CHECK (claim_version > 0),
  version bigint NOT NULL CHECK (version = claim_version + 1),
  descriptor_digest bytea NOT NULL CHECK (octet_length(descriptor_digest) = 32),
  plan_digest bytea NOT NULL CHECK (octet_length(plan_digest) = 32),
  source_seq bigint NOT NULL CHECK (source_seq > 0),
  source_hash bytea NOT NULL CHECK (octet_length(source_hash) = 32),
  read_grant text NOT NULL CHECK (read_grant ~ '^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$'),
  execute_grant text NOT NULL CHECK (execute_grant ~ '^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$'),
  admitted_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  execution_deadline timestamptz NOT NULL,
  CHECK (admitted_at < execution_deadline)
);

COMMENT ON TABLE agent_ops.launch_admissions IS
  'Immutable operational admission receipts. Not proof that a backend exists or permission to execute after revocation.';

CREATE OR REPLACE FUNCTION agent_ops.reject_launch_admission_mutation()
RETURNS trigger LANGUAGE plpgsql SECURITY INVOKER AS $function$
BEGIN
  RAISE EXCEPTION 'launch admission receipts are immutable';
END;
$function$;

DROP TRIGGER IF EXISTS immutable_launch_admissions ON agent_ops.launch_admissions;
CREATE TRIGGER immutable_launch_admissions
  BEFORE UPDATE OR DELETE ON agent_ops.launch_admissions
  FOR EACH ROW EXECUTE FUNCTION agent_ops.reject_launch_admission_mutation();

CREATE OR REPLACE FUNCTION agent_ops.admit_launch(
  p_effect text,
  p_expected_version bigint,
  p_epoch bigint,
  p_token_sha256 bytea,
  p_descriptor_digest bytea,
  p_admission_id text,
  p_source_seq bigint,
  p_source_hash bytea,
  p_read_grant text,
  p_execute_grant text,
  p_plan_digest bytea
)
RETURNS TABLE (
  admission_id text, effect_id text, epoch bigint, claim_version bigint,
  version bigint, source_seq bigint, source_hash bytea, descriptor_digest bytea,
  plan_digest bytea,
  admitted_at timestamptz, execution_deadline timestamptz, disposition text
)
LANGUAGE plpgsql VOLATILE SECURITY INVOKER AS $function$
DECLARE
  a agent_ops.execution_attempts%ROWTYPE;
  receipt agent_ops.launch_admissions%ROWTYPE;
  already_admitted boolean;
  observed_at timestamptz;
BEGIN
  IF p_effect IS NULL OR p_expected_version IS NULL OR p_expected_version < 1
     OR p_epoch IS NULL OR p_epoch < 1
     OR p_token_sha256 IS NULL OR octet_length(p_token_sha256) <> 32
     OR p_descriptor_digest IS NULL OR octet_length(p_descriptor_digest) <> 32
     OR p_plan_digest IS NULL OR octet_length(p_plan_digest) <> 32
     OR p_admission_id IS NULL OR p_admission_id !~ '^agent-admission:[0-9a-f]{64}$'
     OR p_source_seq IS NULL OR p_source_seq < 1
     OR p_source_hash IS NULL OR octet_length(p_source_hash) <> 32
     OR p_read_grant IS NULL OR p_read_grant !~ '^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$'
     OR p_execute_grant IS NULL OR p_execute_grant !~ '^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$'
  THEN RETURN; END IF;

  SELECT * INTO a FROM agent_ops.execution_attempts AS attempt
    WHERE attempt.effect_id = p_effect FOR UPDATE;
  IF NOT FOUND THEN RETURN; END IF;

  -- Observe time after obtaining the lock, never before a database wait.
  observed_at := clock_timestamp();
  IF a.phase <> 'leased' OR a.backend_ref IS NOT NULL
     OR a.attempt_epoch <> p_epoch
     OR a.lease_token_sha256 IS DISTINCT FROM p_token_sha256
     OR a.descriptor_digest IS DISTINCT FROM p_descriptor_digest
     OR a.lease_expires_at IS NULL OR a.lease_expires_at <= observed_at
     OR a.execution_deadline IS NULL OR a.execution_deadline <= observed_at
  THEN RETURN; END IF;

  SELECT * INTO receipt FROM agent_ops.launch_admissions AS existing
    WHERE existing.effect_id = p_effect;
  already_admitted := FOUND;

  IF already_admitted THEN
    -- Reply loss may replay the ORIGINAL claim. Never create another identity
    -- or replace the original source evidence. Cancellation, renewal, expiry
    -- or a different claim invalidates this admission entry point.
    IF receipt.admission_id <> p_admission_id
       OR receipt.epoch <> p_epoch
       OR receipt.claim_version <> p_expected_version
       OR receipt.version <> a.row_version
       OR receipt.descriptor_digest IS DISTINCT FROM p_descriptor_digest
       OR receipt.plan_digest IS DISTINCT FROM p_plan_digest
       OR receipt.read_grant <> p_read_grant
       OR receipt.execute_grant <> p_execute_grant
    THEN RETURN; END IF;
  ELSE
    IF a.row_version <> p_expected_version THEN RETURN; END IF;

    INSERT INTO agent_ops.launch_admissions AS inserted (
      effect_id, admission_id, epoch, claim_version, version,
      descriptor_digest, plan_digest, source_seq, source_hash, read_grant, execute_grant,
      admitted_at, execution_deadline
    ) VALUES (
      p_effect, p_admission_id, p_epoch, p_expected_version, p_expected_version + 1,
      p_descriptor_digest, p_plan_digest, p_source_seq, p_source_hash, p_read_grant, p_execute_grant,
      observed_at, a.execution_deadline
    ) RETURNING inserted.* INTO receipt;

    -- Invalidate subsequent SQL operations using the pre-admission claim.
    -- This cannot recall a legacy adapter call already past validation.
    -- Do not invent a backend reference or mark an execution as running.
    UPDATE agent_ops.execution_attempts AS attempt
       SET row_version = receipt.version, updated_at = observed_at
     WHERE attempt.effect_id = p_effect;
  END IF;

  RETURN QUERY SELECT receipt.admission_id, receipt.effect_id, receipt.epoch,
    receipt.claim_version, receipt.version, receipt.source_seq, receipt.source_hash,
    receipt.descriptor_digest, receipt.plan_digest, receipt.admitted_at, receipt.execution_deadline,
    CASE WHEN already_admitted THEN 'existing'::text ELSE 'admitted'::text END;
END;
$function$;

REVOKE ALL ON agent_ops.launch_admissions FROM PUBLIC;
REVOKE ALL ON FUNCTION agent_ops.reject_launch_admission_mutation() FROM PUBLIC;
REVOKE ALL ON FUNCTION agent_ops.admit_launch(text,bigint,bigint,bytea,bytea,text,bigint,bytea,text,text,bytea) FROM PUBLIC;

COMMIT;
