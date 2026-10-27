-- Disposable PostgreSQL acceptance for the Lean/Quint consumer refinement.
-- No signed business event is created by this fixture. Calls act as the
-- trusted host using predetermined verified event sequences and fingerprints.
\set ON_ERROR_STOP on

DO $contract$
DECLARE
  home text := 'ci-home';
  consumer text := 'ci-proof-consumer';
  a jsonb := '[{"effect_id":"run:1","kind":"eligibility"},{"effect_id":"audit:1","kind":"reconcile"}]'::jsonb;
  b jsonb := '[]'::jsonb;
  d1 bytea := decode(repeat('a1',32),'hex');
  d2 bytea := decode(repeat('b2',32),'hex');
  disposition text;
  ack bigint;
  found_row boolean;
BEGIN
  -- Exact replay of one committed position is idempotent.
  SELECT x.ack_seq, x.disposition INTO ack, disposition
    FROM agent_ops.commit_event_bundle(home,consumer,1,'event-one',d1,a) AS x;
  IF ack <> 1 OR disposition <> 'new' THEN
    RAISE EXCEPTION 'multi-effect first event not committed';
  END IF;
  SELECT x.ack_seq, x.disposition INTO ack, disposition
    FROM agent_ops.commit_event_bundle(home,consumer,1,'event-one',d1,a) AS x;
  IF ack <> 1 OR disposition <> 'existing' THEN
    RAISE EXCEPTION 'duplicate event not idempotent';
  END IF;

  SELECT count(*) = 2 INTO found_row
    FROM agent_ops.consumer_effects
    WHERE home_id=home AND consumer_id=consumer AND global_seq=1;
  IF NOT found_row THEN
    RAISE EXCEPTION 'partial multi-effect persisted';
  END IF;

  -- Incorrect cursor leap is rejected without any persisted effects/receipt.
  BEGIN
    PERFORM * FROM agent_ops.commit_event_bundle(home,consumer,3,'event-three',d1,b);
    RAISE EXCEPTION 'cursor gap unexpectedly admitted';
  EXCEPTION WHEN check_violation THEN NULL;
  END;

  SELECT last_seq = 1 INTO found_row
    FROM agent_ops.consumer_cursors
    WHERE home_id=home AND consumer_id=consumer;
  IF NOT found_row THEN
    RAISE EXCEPTION 'cursor moved after refused gap';
  END IF;

  -- A no-effect event STILL needs its own durable processed receipt.
  SELECT x.ack_seq, x.disposition INTO ack, disposition
    FROM agent_ops.commit_event_bundle(home,consumer,2,'event-two',d2,b) AS x;
  IF ack <> 2 OR disposition <> 'new' THEN
    RAISE EXCEPTION 'no-op event not acknowledged';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM agent_ops.consumer_processed
    WHERE home_id=home AND consumer_id=consumer AND global_seq=2
      AND event_id='event-two' AND effect_bundle='[]'::jsonb
  ) THEN
    RAISE EXCEPTION 'no-op processed receipt missing';
  END IF;

  -- Event identity and immutable bundle must not be changed on replay.
  BEGIN
    PERFORM * FROM agent_ops.commit_event_bundle(home,consumer,1,'event-one',d1,'[]'::jsonb);
    RAISE EXCEPTION 'conflicting bundle unexpectedly admitted';
  EXCEPTION WHEN unique_violation THEN NULL;
  END;

  BEGIN
    PERFORM * FROM agent_ops.commit_event_bundle(home,consumer,2,'changed-event',d2,b);
    RAISE EXCEPTION 'conflicting event id unexpectedly admitted';
  EXCEPTION WHEN unique_violation THEN NULL;
  END;

  -- Duplicate identifiers within a single event cannot be hidden by an
  -- ON CONFLICT DO NOTHING, which would pretend a partial bundle is complete.
  BEGIN
    PERFORM * FROM agent_ops.commit_event_bundle(home,consumer,3,'event-three',d1,
      '[{"effect_id":"dup:3","kind":"do"},{"effect_id":"dup:3","kind":"do"}]'::jsonb);
    RAISE EXCEPTION 'duplicate effect identifier unexpectedly admitted';
  EXCEPTION WHEN invalid_parameter_value THEN NULL;
  END;

  SELECT last_seq = 2 INTO found_row
    FROM agent_ops.consumer_cursors
    WHERE home_id=home AND consumer_id=consumer;
  IF NOT found_row THEN
    RAISE EXCEPTION 'duplicate effect advanced cursor';
  END IF;

  -- Scoped consumer/home checkpoints are independent; federation cannot
  -- coalesce distinct home streams into one global cursor.
  SELECT x.ack_seq, x.disposition INTO ack, disposition
    FROM agent_ops.commit_event_bundle('other-home',consumer,1,'remote-one',d1,b) AS x;
  IF ack <> 1 OR disposition <> 'new' THEN
    RAISE EXCEPTION 'second home cursor was not independent';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM agent_ops.consumer_cursors
    WHERE home_id=home AND consumer_id=consumer AND last_seq=2
  ) THEN
    RAISE EXCEPTION 'first home cursor leaked across home scope';
  END IF;

  -- No recovered raw message can fast-forward the cursor to an unknown head.
  BEGIN
    PERFORM * FROM agent_ops.commit_event_bundle(home,consumer,4,'event-four',d1,b);
    RAISE EXCEPTION 'cursor skip unexpectedly admitted';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
END
$contract$;
