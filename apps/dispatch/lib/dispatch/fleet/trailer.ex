defmodule Dispatch.Fleet.Trailer do
  @moduledoc "A trailer operated by the tenant (Section 10). Identity only, like `Vehicle`."

  use Ash.Resource,
    otp_app: :dispatch,
    domain: Dispatch.Fleet,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "trailers"
    repo Dispatch.Repo
  end

  multitenancy do
    strategy :attribute
    attribute :tenant_id
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :tenant_id, :uuid, allow_nil?: false, public?: true
    attribute :organization_id, :uuid, allow_nil?: false, public?: true
    attribute :unit_number, :string, allow_nil?: false, public?: true
    attribute :plate, :string, public?: true

    attribute :status, :atom do
      constraints one_of: [:ACTIVE, :OUT_OF_SERVICE, :RETIRED]
      default :ACTIVE
      allow_nil? false
      public? true
    end

    create_timestamp :created_at
    update_timestamp :updated_at
    attribute :version, :integer, default: 0, allow_nil?: false
  end

  identities do
    identity :unique_unit_number, [:organization_id, :unit_number]
  end

  actions do
    defaults [:read]

    create :register do
      accept [:tenant_id, :organization_id, :unit_number, :plate, :status]
    end

    read :active do
      filter expr(status == :ACTIVE)
    end
  end

  code_interface do
    define :register
    define :active
  end
end
