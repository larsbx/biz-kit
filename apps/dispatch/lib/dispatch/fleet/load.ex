defmodule Dispatch.Fleet.Load do
  @moduledoc """
  Freight moved under a contract (Section 22.2).

  The rate is the sensitive field. Section 4.2 keeps negotiated rate off broker,
  shipper and receiver surfaces, and Section 23.3 requires field policies to
  hide it even from an actor permitted to read the containing record — so
  `agreed_rate_minor` is not `public?` and is exposed only through an action
  that a rate-bearing capability gates.

  Section 19.2 forbids floating point for money: the amount is integer minor
  units beside an ISO 4217 code, so a rate is never a float that rounds
  differently in two places.
  """

  use Ash.Resource,
    otp_app: :dispatch,
    domain: Dispatch.Fleet,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "loads"
    repo Dispatch.Repo

    # Partial: a load with no broker or no external reference is not a duplicate
    # of another such load. Only a reference that a specific broker actually
    # quoted needs to be unique, and that is what a caller quotes on a call.
    identity_wheres_to_sql unique_external_reference:
                             "external_reference IS NOT NULL AND broker_organization_id IS NOT NULL"
  end

  multitenancy do
    strategy :attribute
    attribute :tenant_id
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :tenant_id, :uuid, allow_nil?: false, public?: true
    attribute :carrier_organization_id, :uuid, allow_nil?: false, public?: true
    attribute :broker_organization_id, :uuid, public?: true

    attribute :external_reference, :string do
      description "The broker's or shipper's own load number, as quoted on a call."
      public? true
    end

    attribute :commodity_text, :string, public?: true

    attribute :status, :atom do
      constraints one_of: [:DRAFT, :TENDERED, :BOOKED, :IN_TRANSIT, :DELIVERED, :CANCELLED]
      default :DRAFT
      allow_nil? false
      public? true
    end

    attribute :currency, :string do
      description "ISO 4217 alphabetic code."
      constraints match: ~r/^[A-Z]{3}$/
      public? true
    end

    attribute :agreed_rate_minor, :integer do
      description """
      Integer minor units of `currency` (Section 19.2). Not public: Section 4.2
      excludes negotiated rate from counterparty surfaces, and Section 23.3
      requires the field to stay hidden even where the record is readable.
      """

      public? false
    end

    create_timestamp :created_at
    update_timestamp :updated_at
    attribute :version, :integer, default: 0, allow_nil?: false
  end

  identities do
    identity :unique_external_reference,
             [:tenant_id, :broker_organization_id, :external_reference],
             where: expr(not is_nil(external_reference) and not is_nil(broker_organization_id))
  end

  relationships do
    has_many :stops, Dispatch.Fleet.Stop do
      destination_attribute :load_id
      sort sequence: :asc
    end

    has_many :load_parties, Dispatch.Fleet.LoadParty do
      destination_attribute :load_id
    end

    has_many :assignments, Dispatch.Fleet.Assignment do
      destination_attribute :load_id
    end
  end

  validations do
    validate {Dispatch.Fleet.Validations.CurrencyWithAmount, []}
  end

  actions do
    defaults [:read]

    create :create_load do
      accept [
        :tenant_id,
        :carrier_organization_id,
        :broker_organization_id,
        :external_reference,
        :commodity_text,
        :status,
        :currency,
        :agreed_rate_minor
      ]
    end

    read :active do
      filter expr(status not in [:DELIVERED, :CANCELLED])
    end

    update :set_status do
      accept [:status]
      require_atomic? false
      argument :expected_version, :integer
      change Dispatch.Accounts.Changes.IncrementVersion
    end

    update :update_nonbinding do
      description """
      Changes that bind nobody: commodity text and the counterparty's own
      reference. Section 23.2 gives a dispatcher `load.update.nonbinding` and
      leaves rate, appointment and acceptance to the proposal and approval flow.
      """

      accept [:commodity_text, :external_reference]
      require_atomic? false
      argument :expected_version, :integer
      change Dispatch.Accounts.Changes.IncrementVersion
    end
  end

  code_interface do
    define :create_load
    define :active
  end
end
