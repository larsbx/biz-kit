defmodule Dispatch.Accounts.OrganizationMembership do
  @moduledoc """
  A user's membership of an organization within a tenant (Section 22.1).

  Membership is not authority. Section 23.2 derives every capability from an
  active `RoleAssignment`, so a membership row says who belongs where and
  nothing about what they may do — which is why an administrator can manage
  memberships (acceptance criterion 14) without thereby gaining operational
  reads.
  """

  use Ash.Resource,
    otp_app: :dispatch,
    domain: Dispatch.Accounts,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "organization_memberships"
    repo Dispatch.Repo

    identity_wheres_to_sql unique_active_membership: "status = 'ACTIVE'"
  end

  multitenancy do
    strategy :attribute
    attribute :tenant_id
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :tenant_id, :uuid, allow_nil?: false, public?: true
    attribute :organization_id, :uuid, allow_nil?: false, public?: true
    attribute :user_id, :uuid, allow_nil?: false, public?: true

    attribute :status, :atom do
      constraints one_of: [:ACTIVE, :SUSPENDED, :ENDED]
      default :ACTIVE
      allow_nil? false
      public? true
    end

    create_timestamp :created_at
    update_timestamp :updated_at
    attribute :version, :integer, default: 0, allow_nil?: false
  end

  identities do
    identity :unique_active_membership, [:organization_id, :user_id],
      where: expr(status == :ACTIVE)
  end

  relationships do
    belongs_to :organization, Dispatch.Accounts.Organization do
      source_attribute :organization_id
      attribute_writable? true
    end

    belongs_to :user, Dispatch.Accounts.User do
      source_attribute :user_id
      attribute_writable? true
    end
  end

  actions do
    defaults [:read]

    create :add do
      accept [:tenant_id, :organization_id, :user_id, :status]
    end

    read :active do
      filter expr(status == :ACTIVE)
    end

    update :end_membership do
      accept []
      require_atomic? false
      argument :expected_version, :integer
      change set_attribute(:status, :ENDED)
      change Dispatch.Accounts.Changes.IncrementVersion
    end
  end

  code_interface do
    define :add
    define :active
  end
end
