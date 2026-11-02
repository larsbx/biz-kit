-- Install after schema.sql in a fresh disposable database only.
-- Operational sender custody and delivery observations; no business authority.
BEGIN;
CREATE TABLE halaqa_receipt_draft.outbound_intents (
  intent_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  sender halaqa_receipt_draft.identifier NOT NULL,
  recipient halaqa_receipt_draft.identifier NOT NULL,
  message_id halaqa_receipt_draft.identifier NOT NULL,
  candidate bytea NOT NULL CHECK (octet_length(candidate) BETWEEN 1 AND 8192),
  candidate_sha256 bytea GENERATED ALWAYS AS (sha256(candidate)) STORED,
  signed_wire bytea NOT NULL CHECK (octet_length(signed_wire) BETWEEN 1 AND 12288),
  test_policy jsonb NOT NULL CHECK (jsonb_typeof(test_policy) = 'object'),
  UNIQUE (sender, recipient, message_id),
  UNIQUE (intent_id, sender, recipient)
);
CREATE TABLE halaqa_receipt_draft.outbound_conflicts (
  intent_id bigint NOT NULL REFERENCES halaqa_receipt_draft.outbound_intents,
  candidate bytea NOT NULL CHECK (octet_length(candidate) BETWEEN 1 AND 8192),
  candidate_sha256 bytea GENERATED ALWAYS AS (sha256(candidate)) STORED,
  signed_wire bytea NOT NULL CHECK (octet_length(signed_wire) BETWEEN 1 AND 12288),
  test_policy jsonb NOT NULL CHECK (jsonb_typeof(test_policy) = 'object'),
  PRIMARY KEY (intent_id, candidate_sha256)
);
CREATE TABLE halaqa_receipt_draft.outbound_delivery (
  intent_id bigint PRIMARY KEY,
  sender halaqa_receipt_draft.identifier NOT NULL,
  recipient halaqa_receipt_draft.identifier NOT NULL,
  generation bigint NOT NULL DEFAULT 0 CHECK (generation >= 0),
  state text NOT NULL DEFAULT 'PENDING_TEST_ONLY'
    CHECK (state IN ('PENDING_TEST_ONLY','UNKNOWN','CONFIRMED_TEST_ONLY','REMOTE_CONFLICT')),
  remote_receipt jsonb,
  FOREIGN KEY (intent_id, sender, recipient)
    REFERENCES halaqa_receipt_draft.outbound_intents(intent_id, sender, recipient),
  CHECK ((state IN ('CONFIRMED_TEST_ONLY','REMOTE_CONFLICT')) = (remote_receipt IS NOT NULL))
);
CREATE INDEX outbound_pending ON halaqa_receipt_draft.outbound_delivery(sender,recipient,intent_id)
  WHERE state IN ('PENDING_TEST_ONLY','UNKNOWN');
CREATE TRIGGER immutable_outbound_intents BEFORE UPDATE OR DELETE OR TRUNCATE
  ON halaqa_receipt_draft.outbound_intents FOR EACH STATEMENT
  EXECUTE FUNCTION halaqa_receipt_draft.immutable_evidence();
CREATE TRIGGER immutable_outbound_conflicts BEFORE UPDATE OR DELETE OR TRUNCATE
  ON halaqa_receipt_draft.outbound_conflicts FOR EACH STATEMENT
  EXECUTE FUNCTION halaqa_receipt_draft.immutable_evidence();

CREATE FUNCTION halaqa_receipt_draft.guard_delivery() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog AS $$
BEGIN
  IF TG_OP <> 'UPDATE' THEN RAISE EXCEPTION 'delivery evidence cannot be removed'; END IF;
  IF (NEW.intent_id,NEW.sender,NEW.recipient) IS DISTINCT FROM
     (OLD.intent_id,OLD.sender,OLD.recipient)
     OR OLD.state IN ('CONFIRMED_TEST_ONLY','REMOTE_CONFLICT')
     OR NOT ((NEW.state = 'UNKNOWN' AND NEW.generation = OLD.generation + 1
              AND NEW.remote_receipt IS NULL)
         OR (OLD.state = 'UNKNOWN' AND NEW.generation = OLD.generation
             AND NEW.state IN ('CONFIRMED_TEST_ONLY','REMOTE_CONFLICT'))) THEN
    RAISE EXCEPTION 'invalid or terminal delivery transition';
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER guard_delivery BEFORE UPDATE OR DELETE
  ON halaqa_receipt_draft.outbound_delivery FOR EACH ROW
  EXECUTE FUNCTION halaqa_receipt_draft.guard_delivery();
CREATE TRIGGER immutable_delivery_truncate BEFORE TRUNCATE
  ON halaqa_receipt_draft.outbound_delivery FOR EACH STATEMENT
  EXECUTE FUNCTION halaqa_receipt_draft.immutable_evidence();

CREATE FUNCTION halaqa_receipt_draft.get_intent(p_intent_id bigint) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog AS $$
  SELECT coalesce((SELECT jsonb_build_object(
    'schema','halaqa-outbox-experiment/draft-0','intent_id',i.intent_id,
    'sender',i.sender,'recipient',i.recipient,'message_id',i.message_id,
    'candidate_sha256',encode(i.candidate_sha256,'hex'),
    'candidate_hex',encode(i.candidate,'hex'),'wire_hex',encode(i.signed_wire,'hex'),
    'test_policy',i.test_policy,'generation',d.generation,'state',d.state,
    'remote_receipt',d.remote_receipt,'authority_verified',false,'production_receiver',false)
    FROM halaqa_receipt_draft.outbound_intents i
    JOIN halaqa_receipt_draft.outbound_delivery d USING (intent_id)
    WHERE i.intent_id=p_intent_id),
    jsonb_build_object('state','NOT_FOUND','authority_verified',false,'production_receiver',false));
$$;

CREATE FUNCTION halaqa_receipt_draft.stage_intent(
  p_candidate bytea,p_wire bytea,p_policy jsonb
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE m jsonb; i halaqa_receipt_draft.outbound_intents;
BEGIN
  PERFORM halaqa_receipt_draft.require_durability();
  IF p_candidate IS NULL OR octet_length(p_candidate) NOT BETWEEN 1 AND 8192
     OR p_wire IS NULL OR octet_length(p_wire) NOT BETWEEN 1 AND 12288
     OR p_policy IS NULL OR jsonb_typeof(p_policy) <> 'object' THEN
    RAISE EXCEPTION 'invalid outbound evidence';
  END IF;
  m := convert_from(p_candidate,'UTF8')::jsonb;
  IF m->>'schema' IS DISTINCT FROM 'halaqa-federation-candidate/draft-0' THEN
    RAISE EXCEPTION 'invalid outbound profile';
  END IF;
  INSERT INTO halaqa_receipt_draft.outbound_intents
    (sender,recipient,message_id,candidate,signed_wire,test_policy)
    VALUES (m->>'sender',m->>'recipient',m->>'message_id',p_candidate,p_wire,p_policy)
    ON CONFLICT (sender,recipient,message_id) DO NOTHING RETURNING * INTO i;
  IF FOUND THEN
    INSERT INTO halaqa_receipt_draft.outbound_delivery(intent_id,sender,recipient)
      VALUES(i.intent_id,i.sender,i.recipient);
  ELSE
    SELECT * INTO STRICT i FROM halaqa_receipt_draft.outbound_intents
      WHERE sender=m->>'sender' AND recipient=m->>'recipient' AND message_id=m->>'message_id';
    IF i.candidate <> p_candidate THEN
      INSERT INTO halaqa_receipt_draft.outbound_conflicts
        (intent_id,candidate,signed_wire,test_policy) VALUES(i.intent_id,p_candidate,p_wire,p_policy)
        ON CONFLICT (intent_id,candidate_sha256) DO NOTHING;
      RETURN halaqa_receipt_draft.get_intent(i.intent_id) ||
        jsonb_build_object('outcome','OUTBOUND_CONTENT_CONFLICT');
    END IF;
  END IF;
  RETURN halaqa_receipt_draft.get_intent(i.intent_id);
END;
$$;

CREATE FUNCTION halaqa_receipt_draft.begin_attempt(p_intent_id bigint) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE d halaqa_receipt_draft.outbound_delivery;
BEGIN
  PERFORM halaqa_receipt_draft.require_durability();
  SELECT * INTO STRICT d FROM halaqa_receipt_draft.outbound_delivery
    WHERE intent_id=p_intent_id FOR UPDATE;
  IF d.state IN ('PENDING_TEST_ONLY','UNKNOWN') THEN
    UPDATE halaqa_receipt_draft.outbound_delivery SET generation=generation+1,state='UNKNOWN'
      WHERE intent_id=p_intent_id;
  END IF;
  RETURN halaqa_receipt_draft.get_intent(p_intent_id);
END;
$$;

CREATE FUNCTION halaqa_receipt_draft.finish_attempt(
  p_intent_id bigint,p_generation bigint,p_reply jsonb
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE
  d halaqa_receipt_draft.outbound_delivery;
  i halaqa_receipt_draft.outbound_intents;
  result_state text;
  expected_keys text[] := ARRAY['schema','status','receipt_id','sender','recipient','message_id',
    'candidate_sha256','authority_verified','production_receiver'];
BEGIN
  PERFORM halaqa_receipt_draft.require_durability();
  SELECT * INTO STRICT d FROM halaqa_receipt_draft.outbound_delivery
    WHERE intent_id=p_intent_id FOR UPDATE;
  IF d.state <> 'UNKNOWN' OR d.generation IS DISTINCT FROM p_generation THEN
    RETURN halaqa_receipt_draft.get_intent(p_intent_id) || jsonb_build_object('outcome','STALE_ATTEMPT');
  END IF;
  SELECT * INTO STRICT i FROM halaqa_receipt_draft.outbound_intents WHERE intent_id=p_intent_id;
  IF p_reply IS NULL OR jsonb_typeof(p_reply) <> 'object'
     OR p_reply->>'schema' IS DISTINCT FROM 'halaqa-receipt-experiment/draft-0'
     OR p_reply->'authority_verified' IS DISTINCT FROM 'false'::jsonb
     OR p_reply->'production_receiver' IS DISTINCT FROM 'false'::jsonb
     OR p_reply->>'sender' IS DISTINCT FROM i.sender::text
     OR p_reply->>'recipient' IS DISTINCT FROM i.recipient::text
     OR p_reply->>'message_id' IS DISTINCT FROM i.message_id::text
     OR jsonb_typeof(p_reply->'receipt_id') IS DISTINCT FROM 'number'
     OR coalesce(p_reply->>'receipt_id','') !~ '^[1-9][0-9]{0,18}$'
     OR coalesce(p_reply->>'candidate_sha256','') !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'unbound or malformed fixture receipt';
  END IF;
  IF p_reply->>'status' = 'STORED_TEST_ONLY'
     AND p_reply->>'candidate_sha256' = encode(i.candidate_sha256,'hex') THEN
    result_state := 'CONFIRMED_TEST_ONLY';
  ELSIF p_reply->>'status' IN ('CONTENT_MISMATCH','CONTENT_CONFLICT')
     AND p_reply->>'candidate_sha256' <> encode(i.candidate_sha256,'hex') THEN
    result_state := 'REMOTE_CONFLICT';
    IF p_reply->>'status' = 'CONTENT_CONFLICT' THEN
      expected_keys := expected_keys || ARRAY['attempted_sha256'];
      IF p_reply->>'attempted_sha256' IS DISTINCT FROM encode(i.candidate_sha256,'hex') THEN
        RAISE EXCEPTION 'unbound attempted content';
      END IF;
    END IF;
  ELSE RAISE EXCEPTION 'receipt cannot settle outbound intent';
  END IF;
  IF p_reply - expected_keys <> '{}'::jsonb THEN RAISE EXCEPTION 'unknown receipt fields'; END IF;
  IF (p_reply->>'receipt_id')::numeric > 9223372036854775807 THEN
    RAISE EXCEPTION 'receipt id exceeds int64';
  END IF;
  UPDATE halaqa_receipt_draft.outbound_delivery SET state=result_state,remote_receipt=p_reply
    WHERE intent_id=p_intent_id;
  RETURN halaqa_receipt_draft.get_intent(p_intent_id);
END;
$$;

CREATE FUNCTION halaqa_receipt_draft.pending_intents(
  p_sender text,p_recipient text,p_after bigint,p_limit integer
) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE items jsonb;
BEGIN
  IF p_after IS NULL OR p_after < 0 OR p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 16 THEN
    RAISE EXCEPTION 'invalid pending page';
  END IF;
  SELECT coalesce(jsonb_agg(halaqa_receipt_draft.get_intent(intent_id) ORDER BY intent_id),'[]'::jsonb)
    INTO items FROM (SELECT intent_id FROM halaqa_receipt_draft.outbound_delivery
      WHERE sender=p_sender AND recipient=p_recipient AND intent_id>p_after
        AND state IN ('PENDING_TEST_ONLY','UNKNOWN') ORDER BY intent_id LIMIT p_limit) page;
  -- This is a bounded work page, not a complete-prefix cursor. Rescan from zero.
  RETURN jsonb_build_object('intents',items,'authority_verified',false,'production_receiver',false);
END;
$$;

REVOKE ALL ON ALL TABLES IN SCHEMA halaqa_receipt_draft FROM PUBLIC;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA halaqa_receipt_draft FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA halaqa_receipt_draft FROM PUBLIC;
COMMIT;
