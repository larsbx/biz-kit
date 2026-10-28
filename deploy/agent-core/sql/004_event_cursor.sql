-- 004: EventStore consumer cursor and atomic operational effect-bundle commit.
--
-- This is NOT another business event store. The signed CoopSubstrate.Log is
-- authoritative; these tables track only that a trusted host has processed
-- particular committed ledger positions. Home IDs are scoped to ONE locally
-- administered biz-kit installation (not a federation-global sequence).
--
-- Important trust boundary: this function does NOT authenticate an envelope,
-- compare it to EventStore's committed head, resolve task grants, or approve
-- an execution. Only a trusted host that has read/verified a committed event
-- via CoopSubstrate.Log may call it. Revoke PUBLIC access and grant narrowly
-- to the coordinator service role after migration review.

BEGIN;

CREATE TABLE IF NOT EXISTS agent_ops.consumer_cursors (
  home_id      text NOT NULL,
  consumer_id  text NOT NULL,
  last_seq     bigint NOT NULL DEFAULT 0 CHECK (last_seq >= 0),
  row_version  bigint NOT NULL DEFAULT 0 CHECK (row_version >= 0),
  updated_at   timestamptz NOT NULL DEFAULT clock_timestamp(),
  PRIMARY KEY (home_id, consumer_id)
);

CREATE TABLE IF NOT EXISTS agent_ops.consumer_processed (
  home_id      text NOT NULL,
  consumer_id  text NOT NULL,
  global_seq   bigint NOT NULL CHECK (global_seq > 0),
  event_id     text NOT NULL,
  event_digest bytea NOT NULL CHECK (octet_length(event_digest) = 32),
  effect_bundle jsonb NOT NULL CHECK (jsonb_typeof(effect_bundle) = 'array'),
  processed_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  PRIMARY KEY (home_id, consumer_id, global_seq),
  UNIQUE (home_id, consumer_id, event_id),
  FOREIGN KEY (home_id, consumer_id)
    REFERENCES agent_ops.consumer_cursors(home_id, consumer_id)
);

-- These are operational candidates, not executable jobs or admitted business
-- facts. In particular, inserting an effect never launches a sandbox.
CREATE TABLE IF NOT EXISTS agent_ops.consumer_effects (
  home_id      text NOT NULL,
  consumer_id  text NOT NULL,
  global_seq   bigint NOT NULL,
  effect_id    text NOT NULL,
  effect_kind  text NOT NULL,
  PRIMARY KEY (home_id, consumer_id, effect_id),
  FOREIGN KEY (home_id, consumer_id, global_seq)
    REFERENCES agent_ops.consumer_processed(home_id, consumer_id, global_seq)
);

CREATE INDEX IF NOT EXISTS consumer_effects_sequence_idx
  ON agent_ops.consumer_effects (home_id, consumer_id, global_seq);

REVOKE ALL ON agent_ops.consumer_cursors FROM PUBLIC;
REVOKE ALL ON agent_ops.consumer_processed FROM PUBLIC;
REVOKE ALL ON agent_ops.consumer_effects FROM PUBLIC;

-- One SQL function call = one PostgreSQL transaction. Under the cursor row
-- lock, register the COMPLETE immutable bundle, its processed receipt (even
-- when empty), and only then advance the cursor. If any statement fails, the
-- entire function/transaction rolls back. A duplicate exact event is a no-op.
CREATE OR REPLACE FUNCTION agent_ops.commit_event_bundle(
  p_home text,
  p_consumer text,
  p_seq bigint,
  p_event_id text,
  p_digest bytea,
  p_bundle jsonb
)
RETURNS TABLE (ack_seq bigint, disposition text)
LANGUAGE plpgsql VOLATILE SECURITY INVOKER
AS $function$
DECLARE
  current_seq bigint;
  previous_id text;
  previous_digest bytea;
  previous_bundle jsonb;
  item jsonb;
  inserted_effects integer;
  n integer;
BEGIN
  IF p_home IS NULL OR p_home !~ '^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$'
     OR p_consumer IS NULL OR p_consumer !~ '^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$'
     OR p_seq IS NULL OR p_seq < 1
     OR p_event_id IS NULL OR p_event_id !~ '^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$'
     OR p_digest IS NULL OR octet_length(p_digest) <> 32
     OR p_bundle IS NULL OR jsonb_typeof(p_bundle) IS DISTINCT FROM 'array'
     OR pg_column_size(p_bundle) > 8192
  THEN
    RAISE EXCEPTION 'invalid event bundle' USING ERRCODE = '22023';
  END IF;

  n := jsonb_array_length(p_bundle);
  IF n > 16 THEN
    RAISE EXCEPTION 'event effect bundle too large' USING ERRCODE = '22023';
  END IF;

  FOR item IN SELECT value FROM jsonb_array_elements(p_bundle) AS e(value) LOOP
    IF jsonb_typeof(item) IS DISTINCT FROM 'object'
       OR jsonb_typeof(item->'effect_id') IS DISTINCT FROM 'string'
       OR jsonb_typeof(item->'kind') IS DISTINCT FROM 'string'
       OR item - 'effect_id' - 'kind' <> '{}'::jsonb
       OR (item->>'effect_id') !~ '^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$'
       OR (item->>'kind') !~ '^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$'
    THEN
      RAISE EXCEPTION 'invalid effect item' USING ERRCODE = '22023';
    END IF;
  END LOOP;

  IF n <> (SELECT count(DISTINCT value->>'effect_id')
           FROM jsonb_array_elements(p_bundle) AS e(value)) THEN
    RAISE EXCEPTION 'duplicate effect identifiers' USING ERRCODE = '22023';
  END IF;

  INSERT INTO agent_ops.consumer_cursors(home_id, consumer_id)
    VALUES (p_home, p_consumer)
    ON CONFLICT (home_id, consumer_id) DO NOTHING;

  SELECT c.last_seq INTO current_seq
    FROM agent_ops.consumer_cursors c
    WHERE c.home_id = p_home AND c.consumer_id = p_consumer
    FOR UPDATE;

  IF p_seq <= current_seq THEN
    SELECT p.event_id, p.event_digest, p.effect_bundle
      INTO previous_id, previous_digest, previous_bundle
      FROM agent_ops.consumer_processed p
      WHERE p.home_id = p_home AND p.consumer_id = p_consumer
        AND p.global_seq = p_seq;

    IF FOUND AND previous_id = p_event_id AND previous_digest = p_digest
       AND previous_bundle = p_bundle THEN
      RETURN QUERY SELECT current_seq, 'existing'::text;
      RETURN;
    END IF;
    RAISE EXCEPTION 'replayed position conflicts with immutable event'
      USING ERRCODE = '23505';
  END IF;

  IF p_seq <> current_seq + 1 THEN
    RAISE EXCEPTION 'event cursor gap: expected %, received %', current_seq + 1, p_seq
      USING ERRCODE = '23514';
  END IF;

  INSERT INTO agent_ops.consumer_processed
    (home_id, consumer_id, global_seq, event_id, event_digest, effect_bundle)
  VALUES
    (p_home, p_consumer, p_seq, p_event_id, p_digest, p_bundle);

  INSERT INTO agent_ops.consumer_effects
    (home_id, consumer_id, global_seq, effect_id, effect_kind)
  SELECT p_home, p_consumer, p_seq,
         element->>'effect_id', element->>'kind'
    FROM jsonb_array_elements(p_bundle) AS item(element);

  GET DIAGNOSTICS inserted_effects = ROW_COUNT;
  IF inserted_effects <> n THEN
    RAISE EXCEPTION 'incomplete event effect bundle' USING ERRCODE = '23514';
  END IF;

  UPDATE agent_ops.consumer_cursors c
    SET last_seq = p_seq,
        row_version = c.row_version + 1,
        updated_at = clock_timestamp()
    WHERE c.home_id = p_home AND c.consumer_id = p_consumer
      AND c.last_seq = current_seq;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'cursor compare-and-swap failed' USING ERRCODE = '40001';
  END IF;

  RETURN QUERY SELECT p_seq, 'new'::text;
END
$function$;

REVOKE ALL ON FUNCTION agent_ops.commit_event_bundle(text,text,bigint,text,bytea,jsonb)
  FROM PUBLIC;

COMMIT;
