defmodule Dispatch.DependencySecurityFixtures.Domain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(Dispatch.DependencySecurityFixtures.Row)
    resource(Dispatch.DependencySecurityFixtures.Link)
  end
end

defmodule Dispatch.DependencySecurityFixtures.Row do
  @moduledoc false
  use Ash.Resource,
    domain: Dispatch.DependencySecurityFixtures.Domain,
    data_layer: AshPostgres.DataLayer

  postgres do
    repo(Dispatch.Repo)
    table("dependency_security_rows")
  end

  multitenancy do
    strategy(:attribute)
    attribute(:tenant_id)
  end

  attributes do
    uuid_primary_key(:id, writable?: true)
    attribute(:tenant_id, :uuid, allow_nil?: false, public?: true)
    attribute(:name, :string, allow_nil?: false, public?: true)
  end

  identities do
    identity(:tenant_name, [:name])
  end

  actions do
    defaults([:read, create: [:id, :name]])
  end

  relationships do
    has_many(:links, Dispatch.DependencySecurityFixtures.Link, destination_attribute: :source_id)

    many_to_many :linked_rows, __MODULE__ do
      through(Dispatch.DependencySecurityFixtures.Link)
      source_attribute_on_join_resource(:source_id)
      destination_attribute_on_join_resource(:destination_id)
    end

    has_many(:through_rows, __MODULE__, through: [:links, :destination])
  end
end

defmodule Dispatch.DependencySecurityFixtures.Link do
  @moduledoc false
  use Ash.Resource,
    domain: Dispatch.DependencySecurityFixtures.Domain,
    data_layer: AshPostgres.DataLayer

  postgres do
    repo(Dispatch.Repo)
    table("dependency_security_links")
  end

  multitenancy do
    strategy(:attribute)
    attribute(:tenant_id)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:tenant_id, :uuid, allow_nil?: false, public?: true)
    attribute(:source_id, :uuid, allow_nil?: false, public?: true)
    attribute(:destination_id, :uuid, allow_nil?: false, public?: true)
  end

  actions do
    defaults([:read, create: [:source_id, :destination_id]])
  end

  relationships do
    belongs_to :destination, Dispatch.DependencySecurityFixtures.Row do
      source_attribute(:destination_id)
      define_attribute?(false)
    end
  end
end
