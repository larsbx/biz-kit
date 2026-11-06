-- This file is the migration source, also executed verbatim by the disposable
-- PostgreSQL acceptance runner. Do not split on semicolons: DO/function bodies
-- contain them. Each top-level statement is separated by -- e3:statement.
SET LOCAL search_path = public, pg_catalog;
-- e3:statement
DO $e3$
BEGIN
  IF current_setting('server_version_num')::integer < 160000 THEN
    RAISE EXCEPTION 'E3 requires PostgreSQL 16 or later';
  END IF;
END
$e3$;
-- e3:statement
CREATE EXTENSION IF NOT EXISTS btree_gist WITH SCHEMA public;
-- e3:statement
DO $e3$
DECLARE
  installed_version text;
BEGIN
  SELECT extversion INTO installed_version FROM pg_extension WHERE extname = 'btree_gist';
  IF NOT EXISTS (
    SELECT 1 FROM pg_opclass c
    JOIN pg_am a ON a.oid = c.opcmethod
    JOIN pg_amop m ON m.amopfamily = c.opcfamily
    JOIN pg_operator o ON o.oid = m.amopopr
    WHERE a.amname = 'gist' AND c.opcdefault
      AND c.opcintype = 'boolean'::regtype
      AND pg_opclass_is_visible(c.oid)
      AND m.amoppurpose = 's' AND o.oprname = '<>'
      AND o.oprleft = 'boolean'::regtype AND o.oprright = 'boolean'::regtype
  ) OR NOT EXISTS (
    SELECT 1 FROM pg_opclass c
    JOIN pg_am a ON a.oid = c.opcmethod
    JOIN pg_amop m ON m.amopfamily = c.opcfamily
    JOIN pg_operator o ON o.oid = m.amopopr
    WHERE a.amname = 'gist' AND c.opcdefault
      AND c.opcintype = 'uuid'::regtype
      AND pg_opclass_is_visible(c.oid)
      AND m.amoppurpose = 's' AND o.oprname = '='
      AND o.oprleft = 'uuid'::regtype AND o.oprright = 'uuid'::regtype
  ) THEN
    RAISE EXCEPTION 'E3 requires visible btree_gist UUID equality and Boolean inequality operator classes (installed version: %)', installed_version
      USING HINT = 'Review the installed extension version and schema. This migration deliberately does not upgrade existing extensions.';
  END IF;
END
$e3$;
-- e3:statement
-- Freeze all assignment writers and participant/role identity changes until the
-- preflight, backfill and immediate constraints commit together.
LOCK TABLE public.assignments, public.participants, public.role_assignments,
  public.role_definitions IN ACCESS EXCLUSIVE MODE;
-- e3:statement
DO $e3$
DECLARE
  invalid_count bigint;
BEGIN
  SELECT count(*) INTO invalid_count
  FROM public.assignments a
  LEFT JOIN public.participants p
    ON p.id = a.operator_participant_id AND p.tenant_id = a.tenant_id
  WHERE p.id IS NULL OR p.user_id IS NULL;
  IF invalid_count > 0 THEN
    RAISE EXCEPTION 'E3 preflight: % assignment(s) have no tenant-matching participant User identity', invalid_count
      USING HINT = 'Reconcile identities explicitly before retrying; no assignment has been changed.';
  END IF;

  SELECT count(*) INTO invalid_count FROM (
    SELECT p.user_id
    FROM public.assignments a
    JOIN public.participants p
      ON p.id = a.operator_participant_id AND p.tenant_id = a.tenant_id
    WHERE a.status = 'ACTIVE'
    GROUP BY p.user_id
    HAVING count(*) > 1 AND bool_or(a.operator_exclusive)
  ) conflicts;
  IF invalid_count > 0 THEN
    RAISE EXCEPTION 'E3 preflight: % global User identity group(s) have conflicting ACTIVE assignments', invalid_count
      USING HINT = 'Resolve the operational conflicts explicitly before retrying; this migration never cancels assignments or changes their modes.';
  END IF;

  SELECT count(*) INTO invalid_count FROM public.assignments
  WHERE status = 'ACTIVE' AND NOT operator_exclusive;
  IF invalid_count > 0 THEN
    RAISE EXCEPTION 'E3 preflight: % ACTIVE concurrent assignment(s) lack original trusted role provenance', invalid_count
      USING HINT = 'The previous schema did not persist the selected grant. Do not infer it from current roles. Reconcile these assignments explicitly before retrying.';
  END IF;
END
$e3$;
-- e3:statement
ALTER TABLE public.assignments
  ADD COLUMN operator_user_id uuid,
  ADD COLUMN operator_role_assignment_id uuid,
  ADD COLUMN operator_role_definition_id uuid;
-- e3:statement
UPDATE public.assignments a
SET operator_user_id = p.user_id
FROM public.participants p
WHERE p.id = a.operator_participant_id AND p.tenant_id = a.tenant_id;
-- e3:statement
ALTER TABLE public.assignments ALTER COLUMN operator_user_id SET NOT NULL;
-- e3:statement
ALTER TABLE public.participants ADD CONSTRAINT participants_tenant_id_id_user_id_key
  UNIQUE (tenant_id, id, user_id);
-- e3:statement
ALTER TABLE public.assignments
  ADD CONSTRAINT assignments_operator_identity_fkey
    FOREIGN KEY (tenant_id, operator_participant_id, operator_user_id)
    REFERENCES public.participants (tenant_id, id, user_id)
    ON UPDATE RESTRICT ON DELETE RESTRICT,
  ADD CONSTRAINT assignments_operator_role_assignment_id_fkey
    FOREIGN KEY (operator_role_assignment_id) REFERENCES public.role_assignments (id)
    ON UPDATE RESTRICT ON DELETE RESTRICT,
  ADD CONSTRAINT assignments_operator_role_definition_id_fkey
    FOREIGN KEY (operator_role_definition_id) REFERENCES public.role_definitions (id)
    ON UPDATE RESTRICT ON DELETE RESTRICT,
  ADD CONSTRAINT assignments_active_concurrent_provenance_check
    CHECK (status <> 'ACTIVE' OR operator_exclusive OR
      (operator_role_assignment_id IS NOT NULL AND operator_role_definition_id IS NOT NULL));
-- e3:statement
CREATE UNIQUE INDEX assignments_active_exclusive_user_uniq
  ON public.assignments (operator_user_id)
  WHERE status = 'ACTIVE' AND operator_exclusive;
-- e3:statement
ALTER TABLE public.assignments ADD CONSTRAINT assignments_active_mixed_user_modes_excl
  EXCLUDE USING gist (operator_user_id WITH =, operator_exclusive WITH <>)
  WHERE (status = 'ACTIVE') NOT DEFERRABLE;
-- e3:statement
CREATE FUNCTION public.dispatch_assignment_immutable_policy_guard()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $e3$
BEGIN
  IF ROW(NEW.id, NEW.tenant_id, NEW.load_id, NEW.operator_participant_id,
         NEW.operator_user_id, NEW.operator_exclusive,
         NEW.operator_role_assignment_id, NEW.operator_role_definition_id)
     IS DISTINCT FROM
     ROW(OLD.id, OLD.tenant_id, OLD.load_id, OLD.operator_participant_id,
         OLD.operator_user_id, OLD.operator_exclusive,
         OLD.operator_role_assignment_id, OLD.operator_role_definition_id) THEN
    RAISE EXCEPTION 'assignment identity and policy are immutable after planning'
      USING ERRCODE = '23514', CONSTRAINT = 'assignments_immutable_policy';
  END IF;
  RETURN NEW;
END
$e3$;
-- e3:statement
CREATE TRIGGER assignments_immutable_policy
BEFORE UPDATE ON public.assignments
FOR EACH ROW EXECUTE FUNCTION public.dispatch_assignment_immutable_policy_guard();
