-- AgentCore operational records. Not a business ledger or permission source.
-- Apply to the SAME governed PostgreSQL database as CoopSubstrate, using an
-- authorized migration role. The Compose fixture is only a local dev database.
-- Production writes must be performed by a trusted host using transactional
-- compare-and-swap and CURRENT signed ledger authority checks.
--
-- This table does not launch workers or turn timeout into permission to retry.

BEGIN;

CREATE SCHEMA IF NOT EXISTS agent_ops;

CREATE TABLE IF NOT EXISTS agent_ops.execution_attempts (
    effect_id              text PRIMARY KEY,
    intent_event_id        text NOT NULL UNIQUE,
    chapter_id             text NOT NULL,
    tenant_id              text NOT NULL,
    project_id             text NOT NULL,
    run_id                 text NOT NULL,
    task_id                text NOT NULL,
    task_version           bigint NOT NULL CHECK (task_version > 0),
    task_source_event_id   text NOT NULL,
    definition_digest      bytea NOT NULL CHECK (octet_length(definition_digest) = 32),
    execution_profile_id   text NOT NULL,
    execution_profile_digest bytea NOT NULL CHECK (octet_length(execution_profile_digest) = 32),
    max_duration_ms        bigint NOT NULL CHECK (max_duration_ms BETWEEN 1 AND 2678400000),
    max_output_bytes       bigint NOT NULL CHECK (max_output_bytes BETWEEN 1 AND 16777216),
    descriptor_digest      bytea NOT NULL CHECK (octet_length(descriptor_digest) = 32),

    phase                  text NOT NULL DEFAULT 'pending'
                           CHECK (phase IN ('pending', 'leased', 'candidate_ready',
                                            'cancel_requested', 'cancelled')),
    attempt_epoch          bigint NOT NULL DEFAULT 0 CHECK (attempt_epoch >= 0),
    attempts               integer NOT NULL DEFAULT 0 CHECK (attempts BETWEEN 0 AND 10),
    lease_owner            text,
    lease_token_sha256     bytea CHECK (
                             lease_token_sha256 IS NULL
                             OR octet_length(lease_token_sha256) = 32
                           ),
    lease_expires_at       timestamptz,
    backend_ref            text,
    candidate_digest      bytea CHECK (
                             candidate_digest IS NULL
                             OR octet_length(candidate_digest) = 32
                           ),
    reconciliation_receipt_id text,
    cancellation_receipt_id   text,
    row_version            bigint NOT NULL DEFAULT 1 CHECK (row_version >= 1),
    created_at             timestamptz NOT NULL DEFAULT clock_timestamp(),
    updated_at             timestamptz NOT NULL DEFAULT clock_timestamp(),

    CONSTRAINT agent_ops_effect_id_matches_intent
      CHECK (effect_id = 'agent-run:' || intent_event_id),
    CONSTRAINT agent_ops_one_run_per_scope
      UNIQUE (chapter_id, tenant_id, project_id, run_id),
    CONSTRAINT agent_ops_valid_lease_shape CHECK (
      (phase = 'leased' AND lease_owner IS NOT NULL
         AND lease_token_sha256 IS NOT NULL AND lease_expires_at IS NOT NULL)
      OR
      (phase <> 'leased' AND lease_owner IS NULL
         AND lease_token_sha256 IS NULL AND lease_expires_at IS NULL)
    ),
    CONSTRAINT agent_ops_candidate_shape CHECK (
      phase <> 'candidate_ready' OR candidate_digest IS NOT NULL
    ),
    CONSTRAINT agent_ops_cancel_receipt_shape CHECK (
      phase <> 'cancelled' OR cancellation_receipt_id IS NOT NULL
    )
);

CREATE INDEX IF NOT EXISTS agent_ops_pending_idx
    ON agent_ops.execution_attempts (phase, created_at)
    WHERE phase = 'pending';

CREATE INDEX IF NOT EXISTS agent_ops_leased_expiry_idx
    ON agent_ops.execution_attempts (lease_expires_at)
    WHERE phase = 'leased';

COMMENT ON TABLE agent_ops.execution_attempts IS
  'Operational, rebuildable agent execution state. Authoritative business intents remain in CoopSubstrate.';

COMMIT;
