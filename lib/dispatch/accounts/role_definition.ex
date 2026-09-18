defmodule Dispatch.Accounts.RoleDefinition do
  @moduledoc """
  A versioned capability manifest (Section 23.2).

  This is the mechanism that makes roles data rather than code. Adding an
  owner-operator, team-driver, courier, or field-technician profile requires a
  new definition and policy tests — not a new user table, not a duplicated API,
  and not an `if role == DRIVER` branch anywhere.

  Two constraints keep that honest:

  - `capabilities_json` may contain only keys from
    `Dispatch.Access.Capabilities`, so a typo cannot silently grant nothing and
    a novel string cannot become an ad hoc permission.
  - `profile_module` may name only a compiled module on the
    `ROLE_PROFILE_MODULE_ALLOWLIST`, so database content cannot load arbitrary
    code (Section 23.2).

  Section 23.3 makes a seeded version immutable once used: a change creates a
  new definition version and an audited reassignment plan, so an existing
  assignment's authority cannot be widened underneath it.
  """

  use Ash.Resource,
    otp_app: :dispatch,
    domain: Dispatch.Accounts,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "role_definitions"
    repo Dispatch.Repo
  end

  multitenancy do
    strategy :attribute
    attribute :tenant_id
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :tenant_id, :uuid, allow_nil?: false, public?: true

    attribute :key, :string do
      description "Stable key. Section 23.2 allows renaming the label, never this."
      allow_nil? false
      public? true
    end

    attribute :label, :string, allow_nil?: false, public?: true

    attribute :capability_schema_version, :integer do
      default 1
      allow_nil? false
      public? true
    end

    attribute :capabilities_json, {:array, :string} do
      description "The granted capability keys. The authority, not the profile module."
      default []
      allow_nil? false
      public? true
    end

    attribute :constraints_json, :map do
      description "Per-capability conditions such as self_only or requires_consent."
      default %{}
      allow_nil? false
      public? true
    end

    attribute :profile_module, :string do
      description "Allowlisted module implementing Dispatch.Access.RoleProfile."
      allow_nil? false
      public? true
    end

    attribute :status, :atom do
      constraints one_of: [:ACTIVE, :SUPERSEDED, :RETIRED]
      default :ACTIVE
      allow_nil? false
      public? true
    end

    create_timestamp :created_at
    update_timestamp :updated_at
    attribute :version, :integer, default: 0, allow_nil?: false
  end

  identities do
    # Section 22.1: role_definitions(tenant_id, key).
    identity :unique_tenant_key, [:tenant_id, :key]
  end

  validations do
    validate {Dispatch.Accounts.Validations.KnownCapabilities, []}
    validate {Dispatch.Accounts.Validations.AllowedProfileModule, []}
  end

  actions do
    defaults [:read]

    create :seed do
      description """
      Creates a definition. Used by the seed script and by tenant provisioning;
      Section 23.3 makes a used version immutable, so a change is a new row.
      """

      accept [
        :tenant_id,
        :key,
        :label,
        :capability_schema_version,
        :capabilities_json,
        :constraints_json,
        :profile_module,
        :status
      ]

      # Re-provisioning may refresh presentation text, but never authority.
      # Capability, constraint, module, or status changes require an explicit
      # new-version migration and reassignment plan.
      upsert? true
      upsert_identity :unique_tenant_key
      upsert_fields [:label]
    end

    read :active do
      filter expr(status == :ACTIVE)
    end

    read :by_key do
      argument :key, :string, allow_nil?: false
      get? true
      filter expr(key == ^arg(:key) and status == :ACTIVE)
    end

    update :relabel do
      description "Section 23.2: presentation may change without changing authority."
      accept [:label]
      require_atomic? false
      change Dispatch.Accounts.Changes.IncrementVersion
    end

    update :supersede do
      description "Retires this version in favour of a newer one."
      accept []
      require_atomic? false
      change set_attribute(:status, :SUPERSEDED)
      change Dispatch.Accounts.Changes.IncrementVersion
    end
  end

  calculations do
    calculate :capabilities, {:array, :string}, expr(capabilities_json)
  end

  code_interface do
    define :seed
    define :active
    define :by_key, args: [:key]
  end
end
