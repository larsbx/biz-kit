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

  policies do
    policy always() do
      authorize_if always()
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :tenant_id, :string, allow_nil?: false
    attribute :name, :string, public?: true
  end

  actions do
    defaults [:read, create: [:name]]
  end

  multitenancy do
    strategy :attribute
    attribute :tenant_id
  end
end
