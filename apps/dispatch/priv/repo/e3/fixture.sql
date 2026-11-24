-- Deliberately minimal pre-migration schema for database policy acceptance.
-- Types, nullability, referenced keys and the original E1 index match the
-- Dispatch schema. This is not an application/authorization fixture.
CREATE FUNCTION public.e3_uuid(n integer) RETURNS uuid
LANGUAGE sql IMMUTABLE STRICT AS $$
  SELECT ('00000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid
$$;
CREATE TABLE users (id uuid PRIMARY KEY);
CREATE TABLE organizations (id uuid PRIMARY KEY, tenant_id uuid NOT NULL);
CREATE TABLE participants (
  id uuid PRIMARY KEY, tenant_id uuid NOT NULL,
  user_id uuid NOT NULL REFERENCES users(id),
  home_organization_id uuid NOT NULL REFERENCES organizations(id),
  status text NOT NULL DEFAULT 'ACTIVE'
);
CREATE UNIQUE INDEX participants_unique_user_home_organization_index
  ON participants(tenant_id, user_id, home_organization_id) WHERE status = 'ACTIVE';
CREATE TABLE role_definitions (
  id uuid PRIMARY KEY, tenant_id uuid NOT NULL,
  profile_module text NOT NULL, status text NOT NULL DEFAULT 'ACTIVE'
);
CREATE TABLE role_assignments (
  id uuid PRIMARY KEY, tenant_id uuid NOT NULL,
  role_definition_id uuid NOT NULL REFERENCES role_definitions(id),
  principal_type text NOT NULL, principal_id uuid NOT NULL,
  organization_id uuid NOT NULL REFERENCES organizations(id),
  scope_type text NOT NULL, scope_id uuid,
  starts_at timestamp(6) without time zone NOT NULL,
  ends_at timestamp(6) without time zone,
  status text NOT NULL DEFAULT 'ACTIVE'
);
CREATE TABLE loads (id uuid PRIMARY KEY, tenant_id uuid NOT NULL);
CREATE TABLE assignments (
  id uuid PRIMARY KEY, tenant_id uuid NOT NULL,
  load_id uuid NOT NULL REFERENCES loads(id),
  operator_participant_id uuid NOT NULL,
  vehicle_id uuid, trailer_id uuid,
  starts_at timestamp(6) without time zone NOT NULL,
  ends_at timestamp(6) without time zone,
  operator_exclusive boolean NOT NULL DEFAULT true,
  status text NOT NULL DEFAULT 'PLANNED',
  created_at timestamp(6) without time zone NOT NULL DEFAULT (now() AT TIME ZONE 'utc'),
  updated_at timestamp(6) without time zone NOT NULL DEFAULT (now() AT TIME ZONE 'utc'),
  version bigint NOT NULL DEFAULT 0
);
CREATE UNIQUE INDEX assignments_one_active_per_operator_index
  ON assignments(tenant_id, operator_participant_id)
  WHERE status = 'ACTIVE' AND operator_exclusive;
INSERT INTO users VALUES (e3_uuid(1)), (e3_uuid(2));
INSERT INTO organizations VALUES
  (e3_uuid(51), e3_uuid(101)), (e3_uuid(52), e3_uuid(102)),
  (e3_uuid(53), e3_uuid(101));
INSERT INTO participants VALUES
  (e3_uuid(11), e3_uuid(101), e3_uuid(1), e3_uuid(51), 'ACTIVE'),
  (e3_uuid(12), e3_uuid(102), e3_uuid(1), e3_uuid(52), 'ACTIVE'),
  (e3_uuid(13), e3_uuid(101), e3_uuid(1), e3_uuid(53), 'ACTIVE'),
  (e3_uuid(14), e3_uuid(102), e3_uuid(2), e3_uuid(52), 'ACTIVE');
INSERT INTO loads VALUES (e3_uuid(21), e3_uuid(101)), (e3_uuid(22), e3_uuid(102));
INSERT INTO role_definitions VALUES
  (e3_uuid(41), e3_uuid(101), 'ConcurrentOperator', 'ACTIVE'),
  (e3_uuid(42), e3_uuid(102), 'ConcurrentOperator', 'ACTIVE');
INSERT INTO role_assignments
  (id, tenant_id, role_definition_id, principal_type, principal_id,
   organization_id, scope_type, starts_at)
SELECT e3_uuid(n + 20), p.tenant_id,
  CASE WHEN p.tenant_id = e3_uuid(101) THEN e3_uuid(41) ELSE e3_uuid(42) END,
  'PARTICIPANT', p.id, p.home_organization_id, 'ORGANIZATION', '2026-01-01'
FROM generate_series(11, 14) n JOIN participants p ON p.id = e3_uuid(n);
