defmodule EatsbotCore.Carts.Cart do
  @moduledoc """
  Represents a shopping cart in the Eatsbot e-commerce system.

  A cart holds cart lines (product variants with quantities) and manages the checkout process.
  Carts have a single currency and calculate totals including discounts. When a customer
  completes checkout, the cart is converted to a delivery order.

  ## Cart Status
  - `:active` - Cart is currently being used
  - `:completed` - Cart has been checked out and converted to a delivery
  - `:abandoned` - Cart was not completed within the expected timeframe

  ## Key Features
  - Single currency per cart (defaults to CLP)
  - Automatic total calculation with discount support
  - Variant addition with quantity and notes
  - Validation ensures variant prices match cart currency
  - Checkout places an Order (and its Delivery, for delivery orders)
  - Real-time updates via PubSub notifications

  ## Checkout Process
  The `checkout` action places an `EatsbotCore.Orders.Order`; see
  `EatsbotCore.Carts.Checkout`. `checkout_delivery` is a deprecated wrapper kept for
  existing GraphQL clients.
  """
  use Ash.Resource,
    otp_app: :eatsbot,
    domain: EatsbotCore.Carts,
    extensions: [AshGraphql.Resource],
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    notifiers: [Ash.Notifier.PubSub, EatsbotCore.Kafka.AshNotifier]

  graphql do
    type :cart

    queries do
      get :get_cart, :read
    end

    mutations do
      create :create_cart, :create
      update :cart_add_variant, :add_variant
      action :cart_checkout, :checkout
      action :cart_checkout_delivery, :checkout_delivery
    end
  end

  postgres do
    table "carts"
    repo Eatsbot.Repo
  end

  policies do
    bypass always() do
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

    attribute :status, :atom do
      constraints one_of: [:active, :completed, :abandoned]
      public? true
      default :active
    end

    attribute :currency, :string do
      public? true
      # TODO use store config
      default "CLP"
    end

    timestamps()
  end

  relationships do
    has_many :cart_lines, EatsbotCore.Carts.CartLine do
      public? true
    end
  end

  actions do
    defaults [:read, :destroy, create: :currency, update: :*]

    action :checkout, :map do
      description "Places an order from this cart. See EatsbotCore.Carts.Checkout."
      transaction? true

      constraints fields: [
                    order_id: [type: :uuid, allow_nil?: false],
                    tracking_key: [type: :uuid, allow_nil?: false],
                    delivery_key: [type: :uuid, allow_nil?: true]
                  ]

      argument :cart_id, :uuid, allow_nil?: false

      argument :fulfillment, :atom,
        allow_nil?: false,
        constraints: [one_of: EatsbotCore.Orders.Transitions.fulfillments()]

      argument :idempotency_key, :string, allow_nil?: false, constraints: [min_length: 1]
      argument :contact, :map, allow_nil?: false

      argument :channel, :atom,
        default: :web,
        constraints: [one_of: [:web, :telegram, :whatsapp, :phone, :pos]]

      argument :tip, :money
      argument :delivery_fee, :money
      argument :scheduled_for, :utc_datetime_usec
      argument :delivery, :map

      run EatsbotCore.Carts.Checkout
    end

    action :checkout_delivery, :term do
      description "Deprecated: use checkout with fulfillment :delivery. Returns the delivery's public key."
      argument :cart_id, :uuid, allow_nil?: false
      argument :delivery_input, :map, allow_nil?: false

      run fn %{arguments: %{cart_id: cart_id, delivery_input: input}}, _ ->
        delivery = Map.drop(input, [:delivery_order, "delivery_order"])

        with {:ok, %{delivery_key: key}} <-
               EatsbotCore.Carts.Cart.checkout(cart_id, :delivery, Ash.UUIDv7.generate(), %{
                 # deliveryInput arrives over GraphQL as JSON, with string keys
                 contact: %{
                   name: delivery[:to_name] || delivery["to_name"],
                   phone: delivery[:to_phone] || delivery["to_phone"]
                 },
                 delivery: delivery
               }),
             do: {:ok, key}
      end
    end

    update :add_variant do
      require_atomic? false
      argument :variant_id, :uuid, allow_nil?: false
      argument :quantity, :integer, default: 1
      argument :notes, :string, default: ""

      change fn %{arguments: %{variant_id: variant_id}} = changeset, _context ->
        variant = Ash.get!(EatsbotCore.Products.Variant, variant_id, load: [:prices])

        changeset
        |> Ash.Changeset.put_context(:variant, variant)
      end

      validate fn %{data: %{currency: currency}, context: %{variant: %{prices: prices}}} =
                    changeset,
                  _context ->
        prices = Ash.load!(prices, :currency, lazy?: true, reuse_values?: true)

        if Enum.any?(prices, fn price -> price.currency == currency end) do
          :ok
        else
          {:error, field: :variant, message: "must have a price for #{currency}"}
        end
      end

      change fn %{
                  arguments: %{quantity: quantity, notes: notes},
                  context: %{variant: variant}
                } = changeset,
                _context ->
        changeset
        |> Ash.Changeset.manage_relationship(
          :cart_lines,
          %{variant_id: variant.id, quantity: quantity, notes: notes},
          type: :create
        )
      end

      change load([
               :total,
               :total_before_discount,
               cart_lines: [:variant, :subtotal, :subtotal_before_discount]
             ])
    end
  end

  code_interface do
    define :create
    define :add_variant, args: [:variant_id, {:optional, :quantity}, {:optional, :notes}]
    define :checkout, args: [:cart_id, :fulfillment, :idempotency_key]
    define :checkout_delivery, args: [:cart_id, :delivery_input]
  end

  aggregates do
    sum :total_before_discount, [:cart_lines], :subtotal_before_discount
  end

  calculations do
    calculate :total,
              :money,
              EatsbotCore.Carts.TotalCalculation
  end
end
