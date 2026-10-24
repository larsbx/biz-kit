-- Operational recovery/candidate custody only. Same governed database; no
-- business event, task completion or signed evidence receipt is created.
-- A trusted host MUST verify backend receipts and fresh ledger authority.
BEGIN;

ALTER TABLE agent_ops.execution_attempts
  ADD COLUMN IF NOT EXISTS execution_deadline timestamptz;

-- Conservative backfill: legacy attempts never gain a new execution budget.
UPDATE agent_ops.execution_attempts
   SET execution_deadline = created_at + max_duration_ms * interval '1 millisecond'
 WHERE attempt_epoch > 0 AND execution_deadline IS NULL;

CREATE OR REPLACE FUNCTION agent_ops.claim_attempt(
  p_effect text,
  p_expected_version bigint,
  p_owner text,
  p_token_sha256 bytea,
  p_lease_ms bigint,
  p_attempt_limit integer
)
RETURNS TABLE (epoch bigint, version bigint)
LANGUAGE sql VOLATILE SECURITY INVOKER
AS $function$
  WITH moment AS MATERIALIZED (SELECT clock_timestamp() AS ts)
  UPDATE agent_ops.execution_attempts AS a
     SET phase = 'leased',
         attempt_epoch = a.attempt_epoch + 1,
         attempts = a.attempts + 1,
         lease_owner = p_owner,
         lease_token_sha256 = p_token_sha256,
         execution_deadline = COALESCE(a.execution_deadline, m.ts + a.max_duration_ms * interval '1 millisecond'),
         lease_expires_at = LEAST(COALESCE(a.execution_deadline, m.ts + a.max_duration_ms * interval '1 millisecond'), m.ts + p_lease_ms * interval '1 millisecond'),
         backend_ref = NULL,
         row_version = a.row_version + 1,
         updated_at = m.ts
    FROM moment m
   WHERE a.effect_id = p_effect
     AND a.row_version = p_expected_version
     AND a.phase = 'pending'
     AND (a.execution_deadline IS NULL OR a.execution_deadline > m.ts)
     AND a.attempts < p_attempt_limit
     AND p_attempt_limit BETWEEN 1 AND 10
     AND p_expected_version >= 1
     AND p_lease_ms BETWEEN 1 AND 300000
     AND p_owner ~ '^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$'
     AND octet_length(p_token_sha256) = 32
  RETURNING a.attempt_epoch, a.row_version;
$function$;

CREATE OR REPLACE FUNCTION agent_ops.renew_attempt(
  p_effect text,
  p_expected_version bigint,
  p_epoch bigint,
  p_token_sha256 bytea,
  p_lease_ms bigint
)
RETURNS TABLE (version bigint, expires_at timestamptz)
LANGUAGE sql VOLATILE SECURITY INVOKER
AS $function$
  WITH moment AS MATERIALIZED (SELECT clock_timestamp() AS ts)
  UPDATE agent_ops.execution_attempts AS a
     SET lease_expires_at = LEAST(a.execution_deadline, GREATEST(
           a.lease_expires_at,
           m.ts + p_lease_ms * interval '1 millisecond'
         )),
         row_version = a.row_version + 1,
         updated_at = m.ts
    FROM moment m
   WHERE a.effect_id = p_effect
     AND a.row_version = p_expected_version
     AND a.attempt_epoch = p_epoch
     AND a.lease_token_sha256 = p_token_sha256
     AND a.phase = 'leased'
     AND a.execution_deadline > m.ts
     AND a.lease_expires_at > m.ts
     AND p_lease_ms BETWEEN 1 AND 300000
     AND octet_length(p_token_sha256) = 32
  RETURNING a.row_version, a.lease_expires_at;
$function$;

CREATE TABLE IF NOT EXISTS agent_ops.backend_observations (
  receipt_id text PRIMARY KEY,
  effect_id text NOT NULL REFERENCES agent_ops.execution_attempts(effect_id),
  epoch bigint NOT NULL CHECK (epoch >= 0),
  backend_ref text,
  outcome text NOT NULL CHECK (outcome IN ('running','absent','cancelled','candidate')),
  receipt_bytes bytea NOT NULL CHECK (octet_length(receipt_bytes) BETWEEN 1 AND 65536),
  recorded_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CHECK (receipt_id = 'obs:' || encode(sha256(receipt_bytes), 'hex'))
);

CREATE TABLE IF NOT EXISTS agent_ops.candidate_custody (
  effect_id text PRIMARY KEY REFERENCES agent_ops.execution_attempts(effect_id),
  epoch bigint NOT NULL CHECK (epoch > 0),
  receipt_id text NOT NULL UNIQUE,
  digest bytea NOT NULL CHECK (octet_length(digest) = 32),
  lease_token_sha256 bytea CHECK (lease_token_sha256 IS NULL OR octet_length(lease_token_sha256)=32),
  bytes bytea NOT NULL CHECK (octet_length(bytes) BETWEEN 0 AND 16777216),
  recorded_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CHECK (sha256(bytes) = digest)
);

REVOKE ALL ON agent_ops.backend_observations, agent_ops.candidate_custody FROM PUBLIC;

CREATE OR REPLACE FUNCTION agent_ops.commit_candidate(
  p_effect text, p_version bigint, p_epoch bigint, p_token bytea, p_bytes bytea
) RETURNS TABLE (version bigint, receipt_id text, digest bytea)
LANGUAGE plpgsql VOLATILE SECURITY INVOKER AS $fn$
DECLARE a agent_ops.execution_attempts; d bytea; receipt text;
BEGIN
  SELECT * INTO a FROM agent_ops.execution_attempts WHERE effect_id=p_effect FOR UPDATE;
  IF NOT FOUND OR p_version IS NULL OR p_epoch IS NULL THEN RETURN; END IF;
  -- A lost acknowledgement can safely retry the exact committed bytes using
  -- the original token digest. This never changes state or revives a lease.
  IF a.phase='candidate_ready' AND a.row_version=p_version+1 AND a.attempt_epoch=p_epoch THEN
    RETURN QUERY SELECT a.row_version,c.receipt_id,c.digest FROM agent_ops.candidate_custody c
      WHERE c.effect_id=p_effect AND c.epoch=p_epoch AND c.lease_token_sha256=p_token AND c.bytes=p_bytes;
    RETURN;
  END IF;
  IF p_version IS NULL OR p_epoch IS NULL
     OR a.row_version<>p_version OR a.attempt_epoch<>p_epoch
     OR a.phase<>'leased' OR a.lease_token_sha256 IS DISTINCT FROM p_token
     OR a.lease_expires_at<=clock_timestamp() OR a.execution_deadline IS NULL
     OR a.execution_deadline<=clock_timestamp()
     OR p_bytes IS NULL OR octet_length(p_bytes)>a.max_output_bytes THEN RETURN; END IF;
  d := sha256(p_bytes);
  receipt := 'candidate:' || encode(sha256(convert_to(p_effect || ':' || p_epoch::text || ':','UTF8') || d),'hex');
  INSERT INTO agent_ops.candidate_custody(effect_id,epoch,receipt_id,digest,lease_token_sha256,bytes)
    VALUES(p_effect,p_epoch,receipt,d,p_token,p_bytes) ON CONFLICT(effect_id) DO NOTHING;
  IF NOT EXISTS(SELECT 1 FROM agent_ops.candidate_custody c WHERE c.effect_id=p_effect
      AND c.epoch=p_epoch AND c.receipt_id=receipt AND c.digest=d AND c.bytes=p_bytes) THEN RETURN; END IF;
  UPDATE agent_ops.execution_attempts SET phase='candidate_ready', candidate_digest=d,
      lease_owner=NULL, lease_token_sha256=NULL, lease_expires_at=NULL,
      row_version=row_version+1, updated_at=clock_timestamp() WHERE effect_id=p_effect;
  RETURN QUERY SELECT a.row_version+1,receipt,d;
END;
$fn$;

-- Verification of receipt provenance, finality and candidate completion time
-- is a trusted host responsibility BEFORE this API. Receipt strings alone are
-- not proofs. CAS fences every replay; observations are bound to effect/epoch.
CREATE OR REPLACE FUNCTION agent_ops.apply_recovery(
  p_effect text, p_version bigint, p_epoch bigint, p_outcome text,
  p_ref text, p_receipt bytea, p_owner text, p_token bytea,
  p_lease_ms bigint, p_bytes bytea
) RETURNS TABLE (version bigint, epoch bigint, phase text)
LANGUAGE plpgsql VOLATILE SECURITY INVOKER AS $fn$
DECLARE a agent_ops.execution_attempts; observation text; d bytea; receipt text;
BEGIN
  SELECT * INTO a FROM agent_ops.execution_attempts WHERE effect_id=p_effect FOR UPDATE;
  IF NOT FOUND OR p_version IS NULL OR p_epoch IS NULL
     OR a.row_version<>p_version OR a.attempt_epoch<>p_epoch
     OR p_outcome IS NULL OR p_outcome NOT IN ('running','absent','cancelled','candidate')
     OR p_receipt IS NULL OR octet_length(p_receipt) NOT BETWEEN 1 AND 65536
     OR (a.backend_ref IS NOT NULL AND a.backend_ref IS DISTINCT FROM p_ref)
     OR (p_outcome<>'absent' AND (p_ref IS NULL OR p_ref !~ '^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$'))
     THEN RETURN; END IF;
  IF a.phase='cancel_requested' THEN
    IF p_outcome NOT IN ('absent','cancelled') THEN RETURN; END IF;
  ELSIF a.phase='leased' AND a.lease_expires_at<=clock_timestamp() THEN
    IF p_outcome IN ('running','absent') AND
       (a.execution_deadline IS NULL OR a.execution_deadline<=clock_timestamp()) THEN RETURN; END IF;
    IF p_outcome='cancelled' THEN RETURN; END IF;
    IF p_outcome='running' AND (p_owner IS NULL OR p_owner !~ '^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$'
       OR p_token IS NULL OR octet_length(p_token)<>32
       OR p_lease_ms IS NULL OR p_lease_ms NOT BETWEEN 1 AND 300000) THEN RETURN; END IF;
    IF p_outcome='candidate' AND (p_bytes IS NULL OR octet_length(p_bytes)>a.max_output_bytes) THEN RETURN; END IF;
  ELSE RETURN;
  END IF;
  observation := 'obs:' || encode(sha256(p_receipt),'hex');
  INSERT INTO agent_ops.backend_observations(receipt_id,effect_id,epoch,backend_ref,outcome,receipt_bytes)
    VALUES(observation,p_effect,p_epoch,p_ref,p_outcome,p_receipt) ON CONFLICT(receipt_id) DO NOTHING;
  IF NOT EXISTS(SELECT 1 FROM agent_ops.backend_observations o WHERE o.receipt_id=observation
      AND o.effect_id=p_effect AND o.epoch=p_epoch AND o.backend_ref IS NOT DISTINCT FROM p_ref
      AND o.outcome=p_outcome AND o.receipt_bytes=p_receipt) THEN RETURN; END IF;
  IF a.phase='cancel_requested' THEN
    UPDATE agent_ops.execution_attempts SET phase='cancelled', cancellation_receipt_id=observation,
      row_version=row_version+1,updated_at=clock_timestamp() WHERE effect_id=p_effect;
  ELSIF p_outcome='running' THEN
    UPDATE agent_ops.execution_attempts SET attempt_epoch=attempt_epoch+1,
      lease_owner=p_owner,lease_token_sha256=p_token,
      lease_expires_at=LEAST(execution_deadline,clock_timestamp()+p_lease_ms*interval '1 millisecond'),
      backend_ref=p_ref,reconciliation_receipt_id=observation,
      row_version=row_version+1,updated_at=clock_timestamp() WHERE effect_id=p_effect;
  ELSIF p_outcome='absent' THEN
    UPDATE agent_ops.execution_attempts SET phase='pending',
      lease_owner=NULL,lease_token_sha256=NULL,lease_expires_at=NULL,
      reconciliation_receipt_id=observation,row_version=row_version+1,updated_at=clock_timestamp()
      WHERE effect_id=p_effect;
  ELSE
    d := sha256(p_bytes);
    receipt := 'candidate:' || encode(sha256(convert_to(p_effect || ':' || p_epoch::text || ':','UTF8') || d),'hex');
    INSERT INTO agent_ops.candidate_custody(effect_id,epoch,receipt_id,digest,bytes)
      VALUES(p_effect,p_epoch,receipt,d,p_bytes) ON CONFLICT(effect_id) DO NOTHING;
    IF NOT EXISTS(SELECT 1 FROM agent_ops.candidate_custody c WHERE c.effect_id=p_effect
        AND c.epoch=p_epoch AND c.receipt_id=receipt AND c.digest=d AND c.bytes=p_bytes) THEN
      RAISE EXCEPTION 'candidate custody conflict';
    END IF;
    UPDATE agent_ops.execution_attempts SET phase='candidate_ready',candidate_digest=d,
      backend_ref=p_ref,lease_owner=NULL,lease_token_sha256=NULL,lease_expires_at=NULL,
      reconciliation_receipt_id=observation,row_version=row_version+1,updated_at=clock_timestamp()
      WHERE effect_id=p_effect;
  END IF;
  RETURN QUERY SELECT x.row_version,x.attempt_epoch,x.phase FROM agent_ops.execution_attempts x WHERE x.effect_id=p_effect;
END;
$fn$;

REVOKE ALL ON FUNCTION agent_ops.commit_candidate(text,bigint,bigint,bytea,bytea) FROM PUBLIC;
REVOKE ALL ON FUNCTION agent_ops.apply_recovery(text,bigint,bigint,text,text,bytea,text,bytea,bigint,bytea) FROM PUBLIC;

COMMIT;
