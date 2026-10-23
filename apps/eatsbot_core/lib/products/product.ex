defmodule EatsbotCore.Products.Product do
  @moduledoc """
  Represents a product in the Eatsbot e-commerce system.

  This module defines the `Product` resource, which is the core entity for items available for sale.
  Products can have multiple variants (e.g., different sizes, colors), pricing in different currencies,
  and can be organized into collections. Products support discount rules, SKU management, and can be
  in different states (enabled, disabled, or hidden).

  ## States
  - `:enabled` - Product is visible and available for purchase
  - `:disabled` - Product is not available for purchase
  - `:hidden` - Product exists but is not displayed to customers

  ## Key Features
  - Multiple variants with different option combinations
  - Multi-currency pricing support
  - Collection organization
  - Discount rule application
  - GraphQL API exposure
  """
  use Ash.Resource,
    otp_app: :eatsbot,
    domain: EatsbotCore.Products,
    extensions: [AshGraphql.Resource, AshAdmin.Resource],
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    notifiers: [EatsbotCore.Kafka.AshNotifier]

  use Gettext, backend: EatsbotCore.Gettext
  alias Ash.Changeset

  graphql do
    type :product

    queries do
      get :get_product, :read
      list :get_available_products, :get_enabled
      list :search_available_products, :search_enabled
    end

    mutations do
    end
  end

  admin do
  end

  postgres do
    table "products"
    repo Eatsbot.Repo

    references do
      # reference :state_history, on_delete: :delete
    end
  end

  field_policies do
    field_policy :* do
      description "the rest of the fields don't require any special policies"
      authorize_if always()
    end
  end

  code_interface do
    define :get_or_create_option, args: [:product, :option]
    define :ensure_option_exists, args: [:option]
    define :add_to_collection, args: [:collection_id]
    define :generate_variants
    define :create
    define :update_price, args: [:money]
  end

  actions do
    defaults [:read, :destroy, create: :*, update: :*]

    read :get_enabled do
      filter expr(state == :enabled)
    end

    read :search_enabled do
      argument :search_string, :string
      filter expr(contains(name, ^arg(:search_string)))
    end

    update :generate_variants do
      require_atomic? false

      change fn %{data: data} = changeset, _ ->
        data =
          Ash.load!(
            data,
            [options: [:option_values]],
            lazy?: true
          )

        %{changeset | data: data}
      end

      change EatsbotCore.Products.Product.VariantGenerator
      change load(variants: [:option_values])
    end

    action :get_or_create_option, :term do
      # return created option using Enum.find
      argument :product, :term, allow_nil?: false
      argument :option, :string, allow_nil?: false

      run fn %{arguments: %{product: product, option: option}}, _ ->
        %{options: options} =
          product =
          product |> EatsbotCore.Products.Product.ensure_option_exists!(option, authorize?: false)

        option_record = options |> Enum.find(&(&1.name == option))

        {:ok, option_record}
      end
    end

    update :ensure_option_exists do
      require_atomic? false
      argument :option, :string, allow_nil?: false

      change load(:options)

      change fn %{arguments: %{option: option}} = changeset, _context ->
        changeset
        |> Changeset.manage_relationship(:options, %{name: option}, type: :create)
      end
    end

    update :add_to_collection do
      require_atomic? false
      argument :collection_id, :string, allow_nil?: false

      change fn %{arguments: %{collection_id: collection_id}} = changeset, _context ->
        changeset
        |> Changeset.manage_relationship(:collections, [%{id: collection_id}], type: :append)
      end
    end

    update :update_price do
      require_atomic? false
      argument :money, :money, allow_nil?: false

      change fn %{arguments: %{money: money}} = changeset, _context ->
        changeset
        |> Changeset.manage_relationship(:prices, [%{money: money}],
          on_no_match: {:create, :create_for_product},
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

    attribute :name, :string, public?: true, allow_nil?: false
    attribute :description, :string, public?: true, allow_nil?: false
    attribute :sku, :string, public?: true, allow_nil?: false

    attribute :state, :atom do
      constraints one_of: [:disabled, :enabled, :hidden]
      allow_nil? false
      public? true
      default :disabled
    end

    attribute :discount_rules, {:array, EatsbotCore.Products.DiscountRule} do
      public? true
      default []
    end

    timestamps()
  end

  relationships do
    belongs_to :type, EatsbotCore.Products.Type do
      public? true
    end

    has_many :prices, EatsbotCore.Products.Price, public?: true

    many_to_many :collections, EatsbotCore.Products.Collection do
      through EatsbotCore.Products.CollectionProduct
      source_attribute_on_join_resource :product_id
      destination_attribute_on_join_resource :collection_id
      public? true
    end

    has_many :variants, EatsbotCore.Products.Variant do
      public? true
    end

    has_many :options, EatsbotCore.Products.Option do
      public? true
    end
  end
end
