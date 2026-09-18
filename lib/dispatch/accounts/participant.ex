defmodule Dispatch.Accounts.Participant do
  @moduledoc """
  A person's operational identity within one tenant (Section 22.1).

  This is what authorization is expressed over, not `User`. ADR-0005: one person
  working for two carriers is one user and two participants, which is what makes
  Section 23.3's rule enforceable — a request selects one role assignment, and
  capabilities never union across tenants merely because a user is shared.

  Section 23.2 keeps the identity type neutral: `DRIVER` is a role assignment
  over a participant, never a column here.
  """

  use Ash.Resource,
    otp_app: :dispatch,
    domain: Dispatch.Accounts,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "participants"
    repo Dispatch.Repo

    # The identity is a partial unique index; AshPostgres needs the predicate
    # to render it. Partial rather than total because Section 22.1 requires one
    # *active* profile per user and home organization — a closed profile must
    # not block re-enrolment.
    identity_wheres_to_sql unique_user_home_organization: "status = 'ACTIVE'"
  end

  multitenancy do
    strategy :attribute
    attribute :tenant_id
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :tenant_id, :uuid, allow_nil?: false, public?: true
    attribute :user_id, :uuid, allow_nil?: false, public?: true
    attribute :home_organization_id, :uuid, allow_nil?: false, public?: true

    attribute :public_name, :string do
      description "Shown to counterparties. Section 4.2 exposes no more than this."
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
    attribute :version, :integer, default: 0, allow_nil?: false
  end

  identities do
    # Section 22.1: one active participant profile per user and home organization.
    identity :unique_user_home_organization, [:user_id, :home_organization_id],
      where: expr(status == :ACTIVE)
  end

  relationships do
    belongs_to :user, Dispatch.Accounts.User do
      source_attribute :user_id
      attribute_writable? true
    end

    belongs_to :home_organization, Dispatch.Accounts.Organization do
      source_attribute :home_organization_id
      attribute_writable? true
    end

    has_many :devices, Dispatch.Accounts.Device do
      destination_attribute :participant_id
    end

    has_many :role_assignments, Dispatch.Accounts.RoleAssignment do
      destination_attribute :principal_id
      filter expr(principal_type == :PARTICIPANT)
    end
  end

  actions do
    defaults [:read]

    create :enroll do
      description "Creates a participant profile for a user within this tenant."
      accept [:tenant_id, :user_id, :home_organization_id, :public_name, :status]
    end

    read :active do
      filter expr(status == :ACTIVE)
    end

    update :rename do
      accept [:public_name]
      require_atomic? false
      change Dispatch.Accounts.Changes.IncrementVersion
    end

    update :set_status do
      accept [:status]
      require_atomic? false
      change Dispatch.Accounts.Changes.IncrementVersion
    end
  end

  code_interface do
    define :enroll
    define :active
  end
end
