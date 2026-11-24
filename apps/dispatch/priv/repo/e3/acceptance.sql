-- These tests assert database invariants. The Ash runtime suite separately
-- checks tenant authorization, trusted profile derivation and lifecycle rules.
SELECT e3_assert('backfill preserves legacy planned exclusive assignment',
  EXISTS (SELECT 1 FROM assignments WHERE id = e3_uuid(100)
    AND operator_user_id = e3_uuid(1) AND operator_exclusive AND status = 'PLANNED'
    AND operator_role_assignment_id IS NULL AND operator_role_definition_id IS NULL));
SELECT e3_assert('backfill preserves legacy inactive concurrent assignment',
  EXISTS (SELECT 1 FROM assignments WHERE id = e3_uuid(101)
    AND operator_user_id = e3_uuid(1) AND NOT operator_exclusive AND status = 'CANCELLED'
    AND operator_role_assignment_id IS NULL AND operator_role_definition_id IS NULL));
SELECT e3_expect_error('legacy concurrent row cannot become ACTIVE without provenance',
  $$UPDATE assignments SET status = 'ACTIVE' WHERE id = e3_uuid(101)$$,
  '23514', 'assignments_active_concurrent_provenance_check');
SELECT e3_assert('global exclusion is immediate',
  EXISTS (SELECT 1 FROM pg_constraint
    WHERE conname = 'assignments_active_mixed_user_modes_excl' AND NOT condeferrable));
SELECT e3_assert('historical E1 index remains',
  to_regclass('public.assignments_one_active_per_operator_index') IS NOT NULL);

DO $$
DECLARE
  other_participant integer;
  first_mode boolean;
  second_mode boolean;
  label text;
BEGIN
  FOREACH other_participant IN ARRAY ARRAY[11, 13, 12] LOOP
    FOREACH first_mode IN ARRAY ARRAY[false, true] LOOP
      FOREACH second_mode IN ARRAY ARRAY[false, true] LOOP
        TRUNCATE assignments;
        label := format('truth table p11/p%s modes %s/%s',
          other_participant, first_mode, second_mode);
        PERFORM e3_insert(200, 11, first_mode);
        IF first_mode OR second_mode THEN
          PERFORM e3_expect_error(label,
            format('SELECT e3_insert(201, %s, %L)', other_participant, second_mode),
            CASE WHEN first_mode AND second_mode THEN '23505' ELSE '23P01' END);
          PERFORM e3_assert(label || ' leaves only the winner',
            (SELECT count(*) = 1 FROM assignments));
        ELSE
          PERFORM e3_insert(201, other_participant, second_mode);
          PERFORM e3_assert(label || ' allows both concurrent profiles',
            (SELECT count(*) = 2 FROM assignments));
        END IF;

        TRUNCATE assignments;
        PERFORM e3_insert(200, 11, first_mode, 'PLANNED');
        PERFORM e3_insert(201, other_participant, second_mode, 'PLANNED');
        UPDATE assignments SET status = 'ACTIVE' WHERE id = e3_uuid(200);
        IF first_mode OR second_mode THEN
          PERFORM e3_expect_error(label || ' activation UPDATE',
            'UPDATE assignments SET status = ''ACTIVE'' WHERE id = e3_uuid(201)',
            CASE WHEN first_mode AND second_mode THEN '23505' ELSE '23P01' END);
          PERFORM e3_assert(label || ' preserves losing plan',
            EXISTS (SELECT 1 FROM assignments WHERE id = e3_uuid(201) AND status = 'PLANNED'));
        ELSE
          UPDATE assignments SET status = 'ACTIVE' WHERE id = e3_uuid(201);
          PERFORM e3_assert(label || ' concurrent activations allowed',
            (SELECT count(*) = 2 FROM assignments WHERE status = 'ACTIVE'));
        END IF;
      END LOOP;
    END LOOP;
  END LOOP;
END
$$;

TRUNCATE assignments;
SELECT e3_insert(210, 11, true);
SELECT e3_insert(211, 14, true);
SELECT e3_assert('different global Users can operate simultaneously',
  (SELECT count(*) = 2 FROM assignments));

TRUNCATE assignments;
SELECT e3_insert(220, 11, true, 'PLANNED');
SELECT e3_insert(221, 12, false, 'PLANNED');
SELECT e3_assert('planning does not reserve a driver', (SELECT count(*) = 2 FROM assignments));
UPDATE assignments SET status = 'ACTIVE' WHERE id = e3_uuid(220);
SELECT e3_expect_error('activation applies mixed global conflict',
  $$UPDATE assignments SET status = 'ACTIVE' WHERE id = e3_uuid(221)$$,
  '23P01', 'assignments_active_mixed_user_modes_excl');
UPDATE assignments SET ends_at = '2000-01-01' WHERE id = e3_uuid(220);
SELECT e3_expect_error('expired time window does not release ACTIVE occupancy',
  $$SELECT e3_insert(222, 12, false)$$, '23P01', 'assignments_active_mixed_user_modes_excl');

TRUNCATE assignments;
SELECT e3_insert(230, 11, true);
BEGIN;
UPDATE assignments SET status = 'CANCELLED' WHERE id = e3_uuid(230);
ROLLBACK;
SELECT e3_expect_error('rolled back cancellation retains occupancy',
  $$SELECT e3_insert(231, 12, false)$$, '23P01');
UPDATE assignments SET status = 'CANCELLED' WHERE id = e3_uuid(230);
SELECT e3_insert(231, 12, false);
SELECT e3_assert('committed cancellation permits reuse',
  (SELECT count(*) = 1 FROM assignments WHERE status = 'ACTIVE'));

TRUNCATE assignments;
SELECT e3_insert(240, 11, true);
BEGIN;
UPDATE assignments SET status = 'COMPLETED' WHERE id = e3_uuid(240);
ROLLBACK;
SELECT e3_expect_error('rolled back completion retains occupancy',
  $$SELECT e3_insert(241, 12, false)$$, '23P01');
UPDATE assignments SET status = 'COMPLETED' WHERE id = e3_uuid(240);
SELECT e3_insert(241, 12, false);
SELECT e3_assert('committed completion permits reuse',
  (SELECT count(*) = 1 FROM assignments WHERE status = 'ACTIVE'));

TRUNCATE assignments;
BEGIN;
SELECT e3_insert(250, 11, true);
ROLLBACK;
SELECT e3_insert(251, 12, false);
SELECT e3_assert('rolled back activation leaves no occupancy', (SELECT count(*) = 1 FROM assignments));

TRUNCATE assignments;
SELECT e3_expect_error('NULL User cannot bypass global constraints',
  $$INSERT INTO assignments (id, tenant_id, load_id, operator_participant_id,
       operator_user_id, starts_at) VALUES
    (e3_uuid(300), e3_uuid(101), e3_uuid(21), e3_uuid(11), NULL, now())$$, '23502');
SELECT e3_expect_error('spoofed User fails composite identity FK',
  $$INSERT INTO assignments (id, tenant_id, load_id, operator_participant_id,
       operator_user_id, starts_at) VALUES
    (e3_uuid(300), e3_uuid(101), e3_uuid(21), e3_uuid(11), e3_uuid(2), now())$$,
  '23503', 'assignments_operator_identity_fkey');
SELECT e3_expect_error('cross-tenant participant spoof fails identity FK',
  $$INSERT INTO assignments (id, tenant_id, load_id, operator_participant_id,
       operator_user_id, starts_at) VALUES
    (e3_uuid(300), e3_uuid(102), e3_uuid(22), e3_uuid(11), e3_uuid(1), now())$$,
  '23503', 'assignments_operator_identity_fkey');
SELECT e3_expect_error('NULL mode cannot bypass global constraints',
  $$INSERT INTO assignments (id, tenant_id, load_id, operator_participant_id,
       operator_user_id, operator_exclusive, starts_at) VALUES
    (e3_uuid(300), e3_uuid(101), e3_uuid(21), e3_uuid(11), e3_uuid(1), NULL, now())$$, '23502');
SELECT e3_expect_error('ACTIVE concurrent mode requires source IDs',
  $$INSERT INTO assignments (id, tenant_id, load_id, operator_participant_id,
       operator_user_id, operator_exclusive, status, starts_at) VALUES
    (e3_uuid(300), e3_uuid(101), e3_uuid(21), e3_uuid(11), e3_uuid(1), false, 'ACTIVE', now())$$,
  '23514', 'assignments_active_concurrent_provenance_check');
SELECT e3_expect_error('nonexistent source role fails FK',
  $$INSERT INTO assignments (id, tenant_id, load_id, operator_participant_id,
       operator_user_id, operator_role_assignment_id, operator_role_definition_id,
       operator_exclusive, status, starts_at) VALUES
    (e3_uuid(300), e3_uuid(101), e3_uuid(21), e3_uuid(11), e3_uuid(1),
     e3_uuid(999), e3_uuid(41), false, 'ACTIVE', now())$$,
  '23503', 'assignments_operator_role_assignment_id_fkey');
SELECT e3_expect_error('nonexistent source definition fails FK',
  $$INSERT INTO assignments (id, tenant_id, load_id, operator_participant_id,
       operator_user_id, operator_role_assignment_id, operator_role_definition_id,
       operator_exclusive, status, starts_at) VALUES
    (e3_uuid(300), e3_uuid(101), e3_uuid(21), e3_uuid(11), e3_uuid(1),
     e3_uuid(31), e3_uuid(999), false, 'ACTIVE', now())$$,
  '23503', 'assignments_operator_role_definition_id_fkey');

SELECT e3_insert(310, 11, true, 'PLANNED');
DO $$
DECLARE
  field text;
BEGIN
  FOREACH field IN ARRAY ARRAY['id', 'tenant_id', 'load_id',
    'operator_participant_id', 'operator_user_id', 'operator_role_assignment_id',
    'operator_role_definition_id'] LOOP
    PERFORM e3_expect_error('immutable ' || field,
      format('UPDATE assignments SET %I = e3_uuid(999) WHERE id = e3_uuid(310)', field),
      '23514', 'assignments_immutable_policy');
  END LOOP;
END
$$;
SELECT e3_expect_error('planned mode cannot be flipped',
  $$UPDATE assignments SET operator_exclusive = false WHERE id = e3_uuid(310)$$,
  '23514', 'assignments_immutable_policy');
UPDATE assignments SET id = id, tenant_id = tenant_id, load_id = load_id,
  operator_participant_id = operator_participant_id, operator_user_id = operator_user_id,
  operator_exclusive = operator_exclusive, operator_role_assignment_id = operator_role_assignment_id,
  operator_role_definition_id = operator_role_definition_id, version = version + 1
WHERE id = e3_uuid(310);
SELECT e3_assert('same-value policy updates remain valid',
  (SELECT version = 1 FROM assignments WHERE id = e3_uuid(310)));
SELECT e3_expect_error('referenced participant User cannot be rebound',
  $$UPDATE participants SET user_id = e3_uuid(2) WHERE id = e3_uuid(11)$$,
  '23503', 'assignments_operator_identity_fkey');
SELECT e3_expect_error('referenced participant tenant cannot be rebound',
  $$UPDATE participants SET tenant_id = e3_uuid(102) WHERE id = e3_uuid(11)$$,
  '23503', 'assignments_operator_identity_fkey');
SELECT e3_expect_error('referenced participant cannot be deleted',
  $$DELETE FROM participants WHERE id = e3_uuid(11)$$,
  '23503', 'assignments_operator_identity_fkey');
UPDATE assignments SET status = 'CANCELLED' WHERE id = e3_uuid(310);
SELECT e3_expect_error('terminal mode remains immutable',
  $$UPDATE assignments SET operator_exclusive = false WHERE id = e3_uuid(310)$$,
  '23514', 'assignments_immutable_policy');
TRUNCATE assignments;
SELECT e3_insert(320, 11, false, 'PLANNED');
SELECT e3_expect_error('selected grant cannot be deleted',
  $$DELETE FROM role_assignments WHERE id = e3_uuid(31)$$,
  '23503', 'assignments_operator_role_assignment_id_fkey');
TRUNCATE assignments;
