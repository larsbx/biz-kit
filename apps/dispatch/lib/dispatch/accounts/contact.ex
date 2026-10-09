defmodule Dispatch.Accounts.Contact do
  @moduledoc """
  A reachable counterparty (Section 22.1).

  A contact is an address book entry and nothing more. Section 22.2 is explicit:
  a contact record, phone number, email address, organization kind, or caller
  claim never grants access by itself. Section 8.5 attaches an inbound message
  to a verified contact thread, and Section 27.3 resolves an unrecognised caller
  to public or minimal information only.
  """

  use Ash.Resource,
    otp_app: :dispatch,
    domain: Dispatch.Accounts,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "contacts"
    repo Dispatch.Repo

    # Section 22.1 scopes this to normalized *active* contacts with a number,
    # so an archived row and a number-less row are both outside the constraint.
    identity_wheres_to_sql unique_active_phone: "status = 'ACTIVE' AND phone_e164 IS NOT NULL"
  end

  multitenancy do
    strategy :attribute
    attribute :tenant_id
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :tenant_id, :uuid, allow_nil?: false, public?: true
    attribute :organization_id, :uuid, allow_nil?: false, public?: true

    attribute :kind, :atom do
      constraints one_of: [:BROKER, :DISPATCHER, :SHIPPER, :RECEIVER, :OTHER]
      allow_nil? false
      public? true
    end

    attribute :name, :string, allow_nil?: false, public?: true

    attribute :phone_e164, :string do
      description "Canonical E.164. Section 27.1 keeps provider formats out of the domain."
      public? true
      constraints match: ~r/^\+[1-9]\d{1,14}$/
    end

    attribute :email, :ci_string, public?: true

    attribute :status, :atom do
      constraints one_of: [:ACTIVE, :ARCHIVED]
      default :ACTIVE
      allow_nil? false
      public? true
    end

    create_timestamp :created_at
    update_timestamp :updated_at
    attribute :version, :integer, default: 0, allow_nil?: false
  end

  identities do
    # Section 22.1: normalized active contacts.phone_e164 within a tenant.
    identity :unique_active_phone, [:tenant_id, :phone_e164],
      where: expr(status == :ACTIVE and not is_nil(phone_e164))
  end

  relationships do
    belongs_to :organization, Dispatch.Accounts.Organization do
      source_attribute :organization_id
      attribute_writable? true
    end
  end

  actions do
    defaults [:read]

    create :add do
      accept [:tenant_id, :organization_id, :kind, :name, :phone_e164, :email, :status]
    end

    read :active do
      filter expr(status == :ACTIVE)
    end

    read :by_phone do
      argument :phone_e164, :string, allow_nil?: false
      get? true
      filter expr(phone_e164 == ^arg(:phone_e164) and status == :ACTIVE)
    end

    update :archive do
      accept []
      require_atomic? false
      argument :expected_version, :integer
      change set_attribute(:status, :ARCHIVED)
      change Dispatch.Accounts.Changes.IncrementVersion
    end
  end

  code_interface do
    define :add
    define :active
    define :by_phone, args: [:phone_e164]
  end
end
