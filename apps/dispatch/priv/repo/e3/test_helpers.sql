CREATE FUNCTION public.e3_insert(n integer, participant integer, exclusive_mode boolean,
  assignment_status text DEFAULT 'ACTIVE') RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE
  result uuid;
BEGIN
  INSERT INTO assignments
    (id, tenant_id, load_id, operator_participant_id, operator_user_id,
     operator_role_assignment_id, operator_role_definition_id,
     operator_exclusive, status, starts_at)
  SELECT e3_uuid(n), p.tenant_id,
    CASE WHEN p.tenant_id = e3_uuid(101) THEN e3_uuid(21) ELSE e3_uuid(22) END,
    p.id, p.user_id,
    CASE WHEN exclusive_mode THEN NULL ELSE e3_uuid(participant + 20) END,
    CASE WHEN exclusive_mode THEN NULL
         WHEN p.tenant_id = e3_uuid(101) THEN e3_uuid(41) ELSE e3_uuid(42) END,
    exclusive_mode, assignment_status, '2026-11-06'
  FROM participants p WHERE p.id = e3_uuid(participant)
  RETURNING id INTO STRICT result;
  RETURN result;
END
$$;
CREATE FUNCTION public.e3_assert(label text, condition boolean) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  IF condition IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL: %', label;
  END IF;
  RAISE NOTICE 'PASS: %', label;
END
$$;
CREATE FUNCTION public.e3_expect_error(label text, statement text, expected_state text,
  expected_constraint text DEFAULT NULL) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
  actual_state text;
  actual_constraint text;
BEGIN
  BEGIN
    EXECUTE statement;
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS actual_state = RETURNED_SQLSTATE,
      actual_constraint = CONSTRAINT_NAME;
    IF actual_state IS DISTINCT FROM expected_state OR
       (expected_constraint IS NOT NULL AND actual_constraint IS DISTINCT FROM expected_constraint) THEN
      RAISE EXCEPTION 'FAIL: % expected % / %, got % / %',
        label, expected_state, expected_constraint, actual_state, actual_constraint;
    END IF;
    RAISE NOTICE 'PASS: %', label;
    RETURN;
  END;
  RAISE EXCEPTION 'FAIL: % unexpectedly succeeded', label;
END
$$;
