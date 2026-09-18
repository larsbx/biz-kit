defmodule Dispatch.Accounts.Organization do
  @moduledoc """
  A company participating in the platform (Section 22.1).

  Global, not tenant-scoped: ADR-0005 makes an organization the thing a tenant
  *is*, and one broker or facility is referenced by many carriers. Section 22.2
  is explicit that an organization kind never grants access by itself — a
  `BROKER` row confers nothing without an active `role_assignment` and a
  matching `load_parties` relationship.
  """

  use Ash.Resource,
    otp_app: :dispatch,
    domain: Dispatch.Accounts,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "organizations"
    repo Dispatch.Repo
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :name, :string, allow_nil?: false, public?: true

    attribute :kind, :atom do
      constraints one_of: [:CARRIER, :BROKER, :SHIPPER, :RECEIVER, :FACILITY]
      allow_nil? false
      public? true
    end

    attribute :status, :atom do
      constraints one_of: [:ACTIVE, :SUSPENDED, :CLOSED]
      default :ACTIVE
      allow_nil? false
      public? true
    end

    create_timestamp :created_at
    update_timestamp :updated_at
  end

  relationships do
    has_many :memberships, Dispatch.Accounts.OrganizationMembership do
      destination_attribute :organization_id
    end
  end

  actions do
    defaults [:read]

    create :register do
      description "Registers an organization. Registration grants no access on its own."
      accept [:name, :kind, :status]
    end

    update :rename do
      description "Changes the display name. Section 23.2 keeps identity in the stable ID."
      accept [:name]
      require_atomic? false
    end

    update :set_status do
      accept [:status]
      require_atomic? false
    end
  end

  code_interface do
    define :register
    define :read_all, action: :read
  end
end
