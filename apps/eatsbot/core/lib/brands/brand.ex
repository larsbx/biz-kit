defmodule EatsbotCore.Brands.Brand do
  @moduledoc """
  Represents a store brand in the Eatsbot e-commerce system.

  Brands represent the top-level business entities in a multi-brand or franchise setup.
  Each brand can have one or more branches (physical locations). Brands may optionally
  connect to a headquarters URL for centralized product and information management.

  ## Key Features
  - Unique brand identity with name
  - Optional headquarters URL for brand federation
  - Has one Branch (physical location)
  - HQ URL is sensitive and not publicly exposed

  ## Use Cases
  - Restaurant chains with multiple locations
  - Franchise businesses
  - Multi-brand e-commerce platforms
  - Centralized brand management systems
  """

  use Ash.Resource,
    otp_app: :eatsbot,
    domain: EatsbotCore.Brands,
    extensions: [AshGraphql.Resource, AshAdmin.Resource],
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    notifiers: [EatsbotCore.Kafka.AshNotifier]

  use Gettext, backend: EatsbotCore.Gettext

  graphql do
    type :brand

    queries do
      read_one :get_brand, :read
    end

    mutations do
    end
  end

  admin do
  end

  postgres do
    table "brands"
    repo Eatsbot.Repo

    references do
    end
  end

  field_policies do
    field_policy :* do
      description "the rest of the fields don't require any special policies"
      authorize_if always()
    end
  end

  code_interface do
    define :create
    define :update
  end

  actions do
    defaults [:read, :destroy, create: :*, update: :*]
  end

  policies do
    bypass always() do
      description "admin has access to every action"
      authorize_if actor_attribute_equals(:access_level, :admin)
    end

    policy action_type(:read) do
      description "read access is always allowed"
      authorize_if always()
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :name, :string do
      allow_nil? false
      sensitive? false
      public? true
    end

    # Define a Headquarters Eatsbot URL to obtain
    # Common brand and products information
    attribute :hq_url, :string do
      allow_nil? true
      sensitive? true
      public? false
    end

    timestamps()
  end

  relationships do
    has_one :branch, EatsbotCore.Brands.Branch do
      public? true
    end
  end
end
