-- Experimental operational storage, never a production migration or business log.
-- Install only in a disposable test database. The trusted fixture host verifies
-- signatures before calling record_candidate; SQL is not a signature verifier.
BEGIN;
CREATE SCHEMA halaqa_receipt_draft;
REVOKE ALL ON SCHEMA halaqa_receipt_draft FROM PUBLIC;

CREATE DOMAIN halaqa_receipt_draft.identifier AS text COLLATE "C"
  CHECK (VALUE COLLATE "C" ~ '^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$');

CREATE TABLE halaqa_receipt_draft.receipts (
  receipt_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  recipient halaqa_receipt_draft.identifier NOT NULL,
  sender halaqa_receipt_draft.identifier NOT NULL,
  message_id halaqa_receipt_draft.identifier NOT NULL,
  candidate bytea NOT NULL CHECK (octet_length(candidate) BETWEEN 1 AND 8192),
  candidate_sha256 bytea GENERATED ALWAYS AS (sha256(candidate)) STORED,
  signed_wire bytea NOT NULL CHECK (octet_length(signed_wire) BETWEEN 1 AND 12288),
  test_policy jsonb NOT NULL CHECK (jsonb_typeof(test_policy) = 'object'),
  recorded_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  UNIQUE (recipient, sender, message_id)
);

CREATE TABLE halaqa_receipt_draft.conflicts (
  receipt_id bigint NOT NULL REFERENCES halaqa_receipt_draft.receipts,
  candidate bytea NOT NULL CHECK (octet_length(candidate) BETWEEN 1 AND 8192),
  candidate_sha256 bytea GENERATED ALWAYS AS (sha256(candidate)) STORED,
  signed_wire bytea NOT NULL CHECK (octet_length(signed_wire) BETWEEN 1 AND 12288),
  test_policy jsonb NOT NULL CHECK (jsonb_typeof(test_policy) = 'object'),
  recorded_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  PRIMARY KEY (receipt_id, candidate_sha256)
);

CREATE FUNCTION halaqa_receipt_draft.immutable_evidence() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog AS $$
BEGIN
  RAISE EXCEPTION 'receipt evidence is append-only';
END;
$$;
CREATE TRIGGER immutable_receipts BEFORE UPDATE OR DELETE OR TRUNCATE
  ON halaqa_receipt_draft.receipts FOR EACH STATEMENT
  EXECUTE FUNCTION halaqa_receipt_draft.immutable_evidence();
CREATE TRIGGER immutable_conflicts BEFORE UPDATE OR DELETE OR TRUNCATE
  ON halaqa_receipt_draft.conflicts FOR EACH STATEMENT
  EXECUTE FUNCTION halaqa_receipt_draft.immutable_evidence();

CREATE FUNCTION halaqa_receipt_draft.receipt_result(
  r halaqa_receipt_draft.receipts
) RETURNS jsonb LANGUAGE sql IMMUTABLE SET search_path = pg_catalog AS $$
  SELECT jsonb_build_object(
    'schema', 'halaqa-receipt-experiment/draft-0',
    'status', 'STORED_TEST_ONLY', 'receipt_id', r.receipt_id,
    'recipient', r.recipient, 'sender', r.sender, 'message_id', r.message_id,
    'candidate_sha256', encode(r.candidate_sha256, 'hex'),
    'authority_verified', false, 'production_receiver', false);
$$;

CREATE FUNCTION halaqa_receipt_draft.require_durability() RETURNS void
LANGUAGE plpgsql SET search_path = pg_catalog AS $$
BEGIN
  IF current_setting('transaction_isolation') <> 'read committed'
     OR current_setting('synchronous_commit') <> 'on'
     OR current_setting('fsync') <> 'on'
     OR current_setting('full_page_writes') <> 'on' THEN
    RAISE EXCEPTION 'unsupported receipt transaction/durability settings';
  END IF;
END;
$$;

CREATE FUNCTION halaqa_receipt_draft.record_candidate(
  p_candidate bytea, p_signed_wire bytea, p_test_policy jsonb
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE
  m jsonb;
  r halaqa_receipt_draft.receipts;
BEGIN
  -- ON CONFLICT's wait and the subsequent SELECT require a fresh command
  -- snapshot. Higher isolation needs transaction retries, not silent reuse.
  PERFORM halaqa_receipt_draft.require_durability();
  IF p_candidate IS NULL OR octet_length(p_candidate) NOT BETWEEN 1 AND 8192
     OR p_signed_wire IS NULL OR octet_length(p_signed_wire) NOT BETWEEN 1 AND 12288
     OR p_test_policy IS NULL OR jsonb_typeof(p_test_policy) <> 'object' THEN
    RAISE EXCEPTION 'invalid receipt evidence';
  END IF;
  m := convert_from(p_candidate, 'UTF8')::jsonb;
  IF m->>'schema' IS DISTINCT FROM 'halaqa-federation-candidate/draft-0' THEN
    RAISE EXCEPTION 'invalid receipt candidate profile';
  END IF;

  INSERT INTO halaqa_receipt_draft.receipts
    (recipient, sender, message_id, candidate, signed_wire, test_policy)
  VALUES (m->>'recipient', m->>'sender', m->>'message_id',
          p_candidate, p_signed_wire, p_test_policy)
  ON CONFLICT (recipient, sender, message_id) DO NOTHING
  RETURNING * INTO r;

  IF NOT FOUND THEN
    SELECT * INTO STRICT r FROM halaqa_receipt_draft.receipts
      WHERE recipient = m->>'recipient' AND sender = m->>'sender'
        AND message_id = m->>'message_id';
    -- Compare original bytes, not a JSON reserialization or a transport ID.
    IF r.candidate <> p_candidate THEN
      INSERT INTO halaqa_receipt_draft.conflicts
        (receipt_id, candidate, signed_wire, test_policy)
      VALUES (r.receipt_id, p_candidate, p_signed_wire, p_test_policy)
      ON CONFLICT (receipt_id, candidate_sha256) DO NOTHING;
      RETURN halaqa_receipt_draft.receipt_result(r) || jsonb_build_object(
        'status', 'CONTENT_CONFLICT',
        'attempted_sha256', encode(sha256(p_candidate), 'hex'));
    END IF;
  END IF;
  -- A caller must commit successfully BEFORE releasing this result as an ACK.
  RETURN halaqa_receipt_draft.receipt_result(r);
END;
$$;

CREATE FUNCTION halaqa_receipt_draft.lookup_receipt(
  p_recipient text, p_sender text, p_message_id text, p_sha256 bytea
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE r halaqa_receipt_draft.receipts;
BEGIN
  IF p_sha256 IS NULL OR octet_length(p_sha256) <> 32 THEN
    RAISE EXCEPTION 'invalid receipt hash';
  END IF;
  SELECT * INTO r FROM halaqa_receipt_draft.receipts
    WHERE recipient = p_recipient AND sender = p_sender AND message_id = p_message_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('status', 'NOT_FOUND',
      'authority_verified', false, 'production_receiver', false);
  END IF;
  RETURN halaqa_receipt_draft.receipt_result(r) || CASE
    WHEN r.candidate_sha256 = p_sha256 THEN '{}'::jsonb
    ELSE jsonb_build_object('status', 'CONTENT_MISMATCH') END;
END;
$$;

REVOKE ALL ON ALL TABLES IN SCHEMA halaqa_receipt_draft FROM PUBLIC;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA halaqa_receipt_draft FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA halaqa_receipt_draft FROM PUBLIC;
COMMIT;
