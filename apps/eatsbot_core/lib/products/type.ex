defmodule EatsbotCore.Products.Type do
  @moduledoc """
  Represents a product type in the Eatsbot e-commerce system.

  Product types define categories of products with shared attributes. For example,
  "Pizza" might be a type with attributes like "diameter" and "weight", while
  "T-Shirt" might have attributes like "fabric" and "fit".

  ## Key Features
  - Defines reusable attribute schemas for products
  - Products can belong to one type
  - Attributes define metadata structure (e.g., weight, dimensions, material)
  - Helps organize products into logical categories

  ## Use Cases
  - "Food Items" type with nutritional attributes
  - "Clothing" type with size and material attributes
  - "Electronics" type with technical specifications
  - "Pizza" type with diameter and cooking time attributes
  """
  use Ash.Resource,
    otp_app: :eatsbot,
    domain: EatsbotCore.Products,
    extensions: [AshGraphql.Resource, AshAdmin.Resource],
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    notifiers: [EatsbotCore.Kafka.AshNotifier]

  graphql do
    type :type
  end

  postgres do
    table "types"
    repo Eatsbot.Repo
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

    attribute :attributes, {:array, EatsbotCore.Products.Attribute} do
      public? true
    end

    timestamps()
  end

  actions do
    defaults [:read, :destroy, create: :*, update: :*]
  end
end
