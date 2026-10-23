defmodule EatsbotCore.Products.Variant do
  @moduledoc """
  Represents a product variant in the Eatsbot e-commerce system.

  A variant is a specific configuration of a product with particular option values
  (e.g., "Large Red T-Shirt" where "Large" and "Red" are option values).
  Each variant has its own SKU, pricing, images, and can have custom attributes.

  ## Key Features
  - Unique combination of option values per product
  - Independent pricing in multiple currencies
  - Custom attributes (e.g., weight, dimensions)
  - Image gallery support
  - Discount rules that can override product-level rules
  - Identity constraint ensures unique variants per option combination

  ## Relationships
  - Belongs to a Product
  - Has multiple Prices (one per currency)
  - Many-to-many with OptionValues (defines the variant configuration)
  - Has many CartLines (tracks usage in shopping carts)
  """
  use Ash.Resource,
    otp_app: :eatsbot,
    domain: EatsbotCore.Products,
    extensions: [AshGraphql.Resource, AshAdmin.Resource],
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    notifiers: [EatsbotCore.Kafka.AshNotifier]

  alias Ash.Changeset

  graphql do
    type :variant

    queries do
      get :get_variant, :read
    end

    mutations do
    end
  end

  admin do
  end

  postgres do
    table "variants"
    repo Eatsbot.Repo

    references do
      reference :product, on_delete: :delete
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
    define :update_price, args: [:money]
  end

  actions do
    defaults [:read, :destroy, create: :*, update: :*]

    update :update_price do
      require_atomic? false
      argument :money, :money, allow_nil?: false

      change fn %{arguments: %{money: money}} = changeset, _context ->
        changeset
        |> Changeset.manage_relationship(:prices, [%{money: money}],
          on_no_match: {:create, :create_for_variant},
          on_match: :ignore
        )
      end

      change load(:prices)
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

  attributes do
    uuid_v7_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true
    end

    attribute :description, :string do
      public? true
    end

    attribute :sku, :string do
      allow_nil? false
      public? true
    end

    attribute :images, {:array, :string} do
      public? true
    end

    attribute :attributes, {:array, EatsbotCore.Products.Attribute}, public?: true

    attribute :discount_rules, {:array, EatsbotCore.Products.DiscountRule} do
      public? true
      default []
    end

    attribute :option_value_ids, {:array, :string},
      public?: true,
      description: "needed for identity"

    timestamps()
  end

  relationships do
    has_many :prices, EatsbotCore.Products.Price, public?: true

    belongs_to :product, EatsbotCore.Products.Product, public?: true

    has_many :cart_lines, EatsbotCore.Carts.CartLine, public?: true

    # the option values this variant represents
    many_to_many :option_values, EatsbotCore.Products.OptionValue do
      through EatsbotCore.Products.VariantOption
      source_attribute_on_join_resource :variant_id
      destination_attribute_on_join_resource :option_value_id
      public? true
    end
  end

  identities do
    identity :unique_variant, [:option_value_ids, :product_id]
  end
end
