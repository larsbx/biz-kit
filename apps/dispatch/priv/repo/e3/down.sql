-- Removing E3 is an explicitly approved maintenance operation. No assignment
-- status or policy is rewritten, and the historical E1 index remains in place.
LOCK TABLE public.assignments, public.participants IN ACCESS EXCLUSIVE MODE;
-- e3:statement
DROP TRIGGER assignments_immutable_policy ON public.assignments;
-- e3:statement
DROP FUNCTION public.dispatch_assignment_immutable_policy_guard();
-- e3:statement
ALTER TABLE public.assignments
  DROP CONSTRAINT assignments_active_mixed_user_modes_excl,
  DROP CONSTRAINT assignments_active_concurrent_provenance_check,
  DROP CONSTRAINT assignments_operator_role_definition_id_fkey,
  DROP CONSTRAINT assignments_operator_role_assignment_id_fkey,
  DROP CONSTRAINT assignments_operator_identity_fkey;
-- e3:statement
DROP INDEX public.assignments_active_exclusive_user_uniq;
-- e3:statement
ALTER TABLE public.assignments
  DROP COLUMN operator_role_definition_id,
  DROP COLUMN operator_role_assignment_id,
  DROP COLUMN operator_user_id;
-- e3:statement
ALTER TABLE public.participants DROP CONSTRAINT participants_tenant_id_id_user_id_key;
-- btree_gist is shared extension infrastructure and is deliberately retained.
