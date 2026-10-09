defmodule Dispatch.Fleet.Stop do
  @moduledoc """
  One place a load is picked up from or delivered to (Section 22.2).

  `position` is PostGIS `geography(Point,4326)`, canonical from the first
  migration (Section 28.2). A Google Place ID for the same address lives in
  `geo_provider_refs` and never here, so switching geocoder does not rewrite a
  stop — that separation is what makes Section 28.6's migration a configuration
  change.

  The appointment window is a fact about the stop; *changing* it is not. Section
  23.2 gives shippers, receivers, brokers and dispatchers `appointment.propose`
  and nothing that writes these fields, because a confirmed appointment is a
  commitment and Section 15's criterion 18 routes every one of them through the
  proposal, approval and execution-receipt flow.
  """

  use Ash.Resource,
    otp_app: :dispatch,
    domain: Dispatch.Fleet,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "stops"
    repo Dispatch.Repo
  end

  multitenancy do
    strategy :attribute
    attribute :tenant_id
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :tenant_id, :uuid, allow_nil?: false, public?: true
    attribute :load_id, :uuid, allow_nil?: false, public?: true

    attribute :sequence, :integer do
      description "Order within the load, from 1."
      constraints min: 1
      allow_nil? false
      public? true
    end

    attribute :kind, :atom do
      constraints one_of: [:PICKUP, :DELIVERY, :OTHER]
      allow_nil? false
      public? true
    end

    attribute :address_text, :string, allow_nil?: false, public?: true

    attribute :position, Dispatch.Geo.Types.Point do
      description "PostGIS geography(Point,4326). Canonical; vendor refs live elsewhere."
      public? true
    end

    attribute :window_start, :utc_datetime_usec, public?: true
    attribute :window_end, :utc_datetime_usec, public?: true

    attribute :contact_name, :string, public?: true

    attribute :contact_phone_e164, :string do
      constraints match: ~r/^\+[1-9]\d{1,14}$/
      public? true
    end

    create_timestamp :created_at
    update_timestamp :updated_at
    attribute :version, :integer, default: 0, allow_nil?: false
  end

  identities do
    identity :unique_sequence_per_load, [:load_id, :sequence]
  end

  relationships do
    belongs_to :load, Dispatch.Fleet.Load do
      source_attribute :load_id
      attribute_writable? true
    end

    has_many :stop_parties, Dispatch.Fleet.StopParty do
      destination_attribute :stop_id
    end
  end

  validations do
    validate {Dispatch.Fleet.Validations.WindowOrder, []}
  end

  actions do
    defaults [:read]

    create :add do
      accept [
        :tenant_id,
        :load_id,
        :sequence,
        :kind,
        :address_text,
        :position,
        :window_start,
        :window_end,
        :contact_name,
        :contact_phone_e164
      ]
    end

    read :for_load do
      argument :load_id, :uuid, allow_nil?: false
      filter expr(load_id == ^arg(:load_id))
    end

    update :update_instructions do
      description """
      Free-text address detail only. The appointment window is deliberately not
      accepted here: Section 15's criterion 18 requires a window change to go
      through proposal and approval like any other commitment.
      """

      accept [:address_text, :contact_name, :contact_phone_e164]
      require_atomic? false
      argument :expected_version, :integer
      change Dispatch.Accounts.Changes.IncrementVersion
    end
  end

  code_interface do
    define :add
    define :for_load, args: [:load_id]
  end
end
