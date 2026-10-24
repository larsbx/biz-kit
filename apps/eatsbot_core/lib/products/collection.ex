defmodule EatsbotCore.Products.Collection do
  @moduledoc """
  Represents a product collection in the Eatsbot e-commerce system.

  Collections are used to organize and group products for easier navigation and discovery.
  Examples include "Summer Sale", "Pizza Menu", "Vegetarian Options", etc.
  Collections can also be marked as brand collections to represent product brands.

  ## Key Features
  - Many-to-many relationship with products
  - Optional image for collection display
  - Can represent brands via `is_brand` flag
  - Used for product categorization and filtering
  - Exposed via GraphQL API

  ## Use Cases
  - Seasonal collections ("Holiday Specials")
  - Category grouping ("Appetizers", "Main Dishes")
  - Brand representation when `is_brand` is true
  - Marketing campaigns and promotions
  """
  use Ash.Resource,
    otp_app: :eatsbot,
    domain: EatsbotCore.Products,
    extensions: [AshGraphql.Resource, AshAdmin.Resource],
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    notifiers: [EatsbotCore.Kafka.AshNotifier]

  use Gettext, backend: EatsbotCore.Gettext

  graphql do
    type :collection

    queries do
      get :get_collection, :read
    end

    mutations do
    end
  end

  admin do
  end

  postgres do
    table "collections"
    repo Eatsbot.Repo

    references do
      # reference :state_history, on_delete: :delete
    end
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

  field_policies do
    field_policy :* do
      description "the rest of the fields don't require any special policies"
      authorize_if always()
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true
    end

    attribute :description, :string do
      public? true
    end

    attribute :image, :string do
      public? true
    end

    attribute :is_brand, :boolean do
      allow_nil? false
      default false
      public? true
    end

    timestamps()
  end

  relationships do
    many_to_many :products, EatsbotCore.Products.Product do
      through EatsbotCore.Products.CollectionProduct
      source_attribute_on_join_resource :product_id
      destination_attribute_on_join_resource :collection_id
    end
  end

  actions do
    defaults [:read, :destroy, create: :*, update: :*]
  end

  code_interface do
    define :create
  end
end
