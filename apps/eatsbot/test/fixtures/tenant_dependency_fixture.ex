defmodule Eatsbot.DependencyFixtures.TenantDomain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource Eatsbot.DependencyFixtures.TenantRecord
  end
end

defmodule Eatsbot.DependencyFixtures.TenantRecord do
  @moduledoc false
  use Ash.Resource,
    domain: Eatsbot.DependencyFixtures.TenantDomain,
    data_layer: Ash.DataLayer.Ets,
    authorizers: [Ash.Policy.Authorizer]

  actions do
    defaults [:read, create: [:name]]
  end

  policies do
    policy always() do
      authorize_if always()
    end
  end

  multitenancy do
    strategy :attribute
    attribute :tenant_id
  end

  attributes do
    uuid_primary_key :id
    attribute :tenant_id, :string, allow_nil?: false
    attribute :name, :string, public?: true
  end
end
