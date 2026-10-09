defmodule Dispatch.Accounts.RoleAssignment do
  @moduledoc """
  A principal's authority, bounded by organization, scope, and time (Section 22.1).

  Authentication identifies a `User` or service principal; authorization is this
  row. Section 23.2 forbids branching on a hard-coded role column, so every
  check resolves a capability through the assignment's definition.

  Three properties matter more than the columns:

  **It expires.** `starts_at`/`ends_at` bound authority in time, and Section
  23.3 requires an expired or revoked assignment to fail closed across REST,
  Datastar, agent tools, jobs, and SSE reconnects alike.

  **It does not union.** Section 23.3: when one user holds several assignments,
  every request selects or derives exactly one and records it in the audit
  event. Capabilities are never combined merely because assignments share a
  user; `Dispatch.Access` offers no function that would.

  **It is not sufficient on its own.** For `LOAD` and `STOP` scopes, Section
  22.2 additionally requires a matching active `load_parties` or `stop_parties`
  row. An organization kind, contact record, phone number, or caller claim
  never grants access by itself.
  """

  use Ash.Resource,
    otp_app: :dispatch,
    domain: Dispatch.Accounts,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "role_assignments"
    repo Dispatch.Repo

    # Partial: a revoked grant must not block re-granting the same authority.
    identity_wheres_to_sql unique_active_grant: "status = 'ACTIVE'"
  end

  multitenancy do
    strategy :attribute
    attribute :tenant_id
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :tenant_id, :uuid, allow_nil?: false, public?: true

    attribute :principal_type, :atom do
      constraints one_of: [:PARTICIPANT, :SERVICE]
      allow_nil? false
      public? true
    end

    attribute :principal_id, :uuid, allow_nil?: false, public?: true
    attribute :organization_id, :uuid, allow_nil?: false, public?: true
    attribute :role_definition_id, :uuid, allow_nil?: false, public?: true

    attribute :scope_type, :atom do
      constraints one_of: [:SELF, :ORGANIZATION, :LOAD, :STOP, :ASSIGNMENT]
      allow_nil? false
      public? true
    end

    attribute :scope_id, :uuid do
      description "Null for SELF and ORGANIZATION scopes, which the organization already bounds."
      public? true
    end

    attribute :starts_at, :utc_datetime_usec, allow_nil?: false, public?: true
    attribute :ends_at, :utc_datetime_usec, public?: true

    attribute :status, :atom do
      constraints one_of: [:ACTIVE, :REVOKED, :EXPIRED]
      default :ACTIVE
      allow_nil? false
      public? true
    end

    create_timestamp :created_at
    update_timestamp :updated_at
    attribute :version, :integer, default: 0, allow_nil?: false
  end

  identities do
    # Section 22.1: no overlapping duplicate active role assignment for the same
    # participant, organization, role, and scope. Two identical grants would
    # make revoking one look like revoking authority while the other still
    # stands.
    # `nils_distinct?: false` is load-bearing. `scope_id` is NULL for SELF and
    # ORGANIZATION scopes, and PostgreSQL's default treats every NULL as
    # distinct — so with the default this index would permit unlimited duplicate
    # grants for exactly the two scopes the seeded profiles use most. Section
    # 22.1 requires no overlapping duplicate active assignment for the same
    # participant, organization, role, and scope; NULLS NOT DISTINCT is what
    # makes that true rather than nearly true.
    identity :unique_active_grant,
             [
               :principal_type,
               :principal_id,
               :organization_id,
               :role_definition_id,
               :scope_type,
               :scope_id
             ],
             where: expr(status == :ACTIVE),
             nils_distinct?: false
  end

  relationships do
    belongs_to :role_definition, Dispatch.Accounts.RoleDefinition do
      source_attribute :role_definition_id
      attribute_writable? true
    end

    belongs_to :organization, Dispatch.Accounts.Organization do
      source_attribute :organization_id
      attribute_writable? true
    end
  end

  validations do
    validate {Dispatch.Accounts.Validations.ScopeShape, []}
    validate {Dispatch.Accounts.Validations.SelfServicePrincipal, []}
  end

  actions do
    defaults [:read]

    create :grant do
      description """
      Grants authority. Section 23.3 requires administrative role-management
      mutations to carry recent step-up authentication and an idempotency key;
      those are enforced at the API boundary, which is the only place that can
      observe them.
      """

      accept [
        :tenant_id,
        :principal_type,
        :principal_id,
        :organization_id,
        :role_definition_id,
        :scope_type,
        :scope_id,
        :starts_at,
        :ends_at
      ]

      change set_attribute(:status, :ACTIVE)
    end

    read :active do
      description """
      Assignments in force at `at`, defaulting to now.

      The instant is an argument so a policy check, a job, and a test all ask
      about the same moment rather than each reading its own clock.
      """

      argument :at, :utc_datetime_usec, default: &DateTime.utc_now/0

      filter expr(
               status == :ACTIVE and starts_at <= ^arg(:at) and
                 (is_nil(ends_at) or ends_at > ^arg(:at))
             )
    end

    read :for_principal do
      argument :principal_id, :uuid, allow_nil?: false
      argument :at, :utc_datetime_usec, default: &DateTime.utc_now/0

      filter expr(
               principal_id == ^arg(:principal_id) and status == :ACTIVE and
                 starts_at <= ^arg(:at) and (is_nil(ends_at) or ends_at > ^arg(:at))
             )
    end

    update :revoke do
      description "Ends authority immediately. Section 23.3 requires this to fail closed everywhere at once."
      accept []
      require_atomic? false
      argument :expected_version, :integer

      change set_attribute(:status, :REVOKED)
      change set_attribute(:ends_at, &DateTime.utc_now/0)
      change Dispatch.Accounts.Changes.IncrementVersion
      change optimistic_lock(:version)
    end
  end

  code_interface do
    define :grant
    define :active
    define :for_principal, args: [:principal_id]
    define :revoke
  end
end
