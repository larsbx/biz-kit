defmodule Dispatch.Fleet.LoadParty do
  @moduledoc """
  An organization's contractual relationship to a load (Section 22.2).

  This is the second half of every `LOAD`-scoped authorization decision. Section
  22.2 is unambiguous: such a grant "requires both an active `role_assignment`
  and a matching active `load_parties` relationship. A contact record, phone
  number, email address, organization kind, or caller claim never grants access
  by itself."

  The separation matters because the two expire independently. A broker's role
  assignment may still be valid after the contract ends, and acceptance
  criterion 19 requires an unrelated load to return no existence-bearing
  metadata at all — not a denial that confirms the load exists.

  Relationships are time-bounded rather than deleted, so the history of who was
  party to a load when remains readable while present access does not.
  """

  use Ash.Resource,
    otp_app: :dispatch,
    domain: Dispatch.Fleet,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "load_parties"
    repo Dispatch.Repo

    # Partial, so ending a relationship frees the slot for the same
    # organization to re-enter it later in the same role.
    identity_wheres_to_sql unique_active_relationship: "status = 'ACTIVE'"
  end

  multitenancy do
    strategy :attribute
    attribute :tenant_id
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :tenant_id, :uuid, allow_nil?: false, public?: true
    attribute :load_id, :uuid, allow_nil?: false, public?: true
    attribute :organization_id, :uuid, allow_nil?: false, public?: true

    attribute :relationship, :atom do
      constraints one_of: [:BROKER, :SHIPPER, :RECEIVER, :CARRIER]
      allow_nil? false
      public? true
    end

    attribute :starts_at, :utc_datetime_usec, allow_nil?: false, public?: true

    attribute :ends_at, :utc_datetime_usec do
      description "Null means open-ended. Exclusive, like a role assignment's."
      public? true
    end

    attribute :status, :atom do
      constraints one_of: [:ACTIVE, :ENDED]
      default :ACTIVE
      allow_nil? false
      public? true
    end

    create_timestamp :created_at
    update_timestamp :updated_at
    attribute :version, :integer, default: 0, allow_nil?: false
  end

  identities do
    # Section 22.2 requires constraints preventing duplicate overlapping active
    # party relationships of the same kind. Two identical active rows would make
    # ending one look like ending the relationship while the other still grants.
    identity :unique_active_relationship, [:load_id, :organization_id, :relationship],
      where: expr(status == :ACTIVE)
  end

  relationships do
    belongs_to :load, Dispatch.Fleet.Load do
      source_attribute :load_id
      attribute_writable? true
    end

    belongs_to :organization, Dispatch.Accounts.Organization do
      source_attribute :organization_id
      attribute_writable? true
    end
  end

  actions do
    defaults [:read]

    create :add do
      accept [:tenant_id, :load_id, :organization_id, :relationship, :starts_at, :ends_at]
      change set_attribute(:status, :ACTIVE)
    end

    read :active do
      description "Relationships in force at `at`, defaulting to now."
      argument :at, :utc_datetime_usec, default: &DateTime.utc_now/0

      filter expr(
               status == :ACTIVE and starts_at <= ^arg(:at) and
                 (is_nil(ends_at) or ends_at > ^arg(:at))
             )
    end

    read :for_load do
      argument :load_id, :uuid, allow_nil?: false
      argument :at, :utc_datetime_usec, default: &DateTime.utc_now/0

      filter expr(
               load_id == ^arg(:load_id) and status == :ACTIVE and starts_at <= ^arg(:at) and
                 (is_nil(ends_at) or ends_at > ^arg(:at))
             )
    end

    update :end_relationship do
      description """
      Ends the relationship now. Acceptance criterion 15 requires that removing
      it terminates REST, page, and SSE access immediately, so this sets
      `ends_at` rather than waiting for a scheduled sweep.
      """

      accept []
      require_atomic? false
      argument :expected_version, :integer

      change set_attribute(:status, :ENDED)
      change set_attribute(:ends_at, &DateTime.utc_now/0)
      change Dispatch.Accounts.Changes.IncrementVersion
    end
  end

  code_interface do
    define :add
    define :active
    define :for_load, args: [:load_id]
    define :end_relationship
  end
end
