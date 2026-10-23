defmodule EatsbotCore.Orders.Order do
  @moduledoc """
  An order: what was bought, at what price, and where it is in the kitchen.

  Invariants (spec epic E0.1), each with a test in `test/eatsbot/orders/`:

  - I₁ lines and amounts never change after placement: no update action accepts an
    attribute, and `OrderLine` has no update or destroy action
  - I₂ amounts are derived only by `EatsbotCore.Orders.Pricing`
  - I₃ `state` changes only along `EatsbotCore.Orders.Transitions`
  - I₄ a delivery order has exactly one `Delivery`, other fulfillments none
  - I₅ one order per cart, and checkout is idempotent per (channel, key)
  - I₆ `state_changes` replays to `state`
  """
  use Ash.Resource,
    otp_app: :eatsbot,
    domain: EatsbotCore.Orders,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    notifiers: [Ash.Notifier.PubSub, EatsbotCore.Kafka.AshNotifier]

  alias EatsbotCore.Orders.{ActorIn, PriceOrder, Transition, Transitions}

  @kitchen [:admin, :staff]
  @internal [:admin, :staff, :system]

  postgres do
    table "orders"
    repo Eatsbot.Repo

    references do
      reference :cart, on_delete: :nilify
    end
  end

  field_policies do
    field_policy [:contact, :tracking_key, :idempotency_key, :external_ref, :cart_id] do
      description "personal data and keys are hidden from public tracking"
      authorize_if {ActorIn, levels: @internal}
    end

    field_policy :* do
      authorize_if always()
    end
  end

  code_interface do
    define :place
    define :track, args: [:tracking_key], get?: true
    define :board
    define :accept
    define :start_preparing
    define :mark_ready
    define :dispatch
    define :complete
    define :cancel, args: [:reason]
    define :fail, args: [:reason]
  end

  actions do
    defaults [:read]

    create :place do
      description "Used by Cart.checkout and marketplace imports; prices the order and snapshots its lines."

      accept [
        :cart_id,
        :channel,
        :fulfillment,
        :currency,
        :contact,
        :scheduled_for,
        :idempotency_key,
        :external_ref,
        :discount_total,
        :tax_total,
        :delivery_fee,
        :tip
      ]

      argument :lines, {:array, :map}, allow_nil?: false
      change PriceOrder
    end

    read :track do
      description "Public order tracking by the key returned at checkout."
      argument :tracking_key, :uuid, allow_nil?: false
      get? true
      filter expr(tracking_key == ^arg(:tracking_key))
    end

    read :board do
      description "Open orders, oldest first."
      filter expr(state not in ^Transitions.terminal_states())
      prepare build(sort: [inserted_at: :asc])
    end

    for {name, to} <- [
          accept: :accepted,
          start_preparing: :preparing,
          mark_ready: :ready,
          dispatch: :dispatched,
          complete: :completed
        ] do
      update name do
        accept []
        require_atomic? false
        change {Transition, to: to}
      end
    end

    for {name, to} <- [cancel: :cancelled, fail: :failed] do
      update name do
        accept []
        require_atomic? false
        argument :reason, :string, allow_nil?: false, constraints: [min_length: 1]
        change {Transition, to: to}
      end
    end
  end

  policies do
    bypass {ActorIn, levels: [:admin]} do
      authorize_if always()
    end

    policy action(:track) do
      authorize_if always()
    end

    policy action([:read, :board]) do
      authorize_if {ActorIn, levels: @internal}
    end

    policy action(:place) do
      authorize_if {ActorIn, levels: [:system]}
    end

    policy action([:accept, :start_preparing, :mark_ready, :cancel]) do
      authorize_if {ActorIn, levels: @kitchen}
    end

    policy action([:dispatch, :fail]) do
      authorize_if {ActorIn, levels: [:system]}
    end

    policy action(:complete) do
      authorize_if {ActorIn, levels: @internal}
    end
  end

  pub_sub do
    module EatsbotWeb.Endpoint
    prefix "orders"
    publish_all :update, ["updated", :id]
    publish_all :create, ["created"]
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :channel, :atom do
      allow_nil? false
      public? true
      default :web
      constraints one_of: [:web, :telegram, :whatsapp, :phone, :aggregator, :pos]
    end

    attribute :fulfillment, :atom do
      allow_nil? false
      public? true
      constraints one_of: Transitions.fulfillments()
    end

    attribute :state, :atom do
      allow_nil? false
      public? true
      writable? false
      default Transitions.initial_state()
      constraints one_of: Transitions.states()
    end

    attribute :currency, :string, allow_nil?: false, public?: true
    attribute :subtotal, :money, allow_nil?: false, public?: true
    attribute :discount_total, :money, allow_nil?: false, public?: true
    attribute :tax_total, :money, allow_nil?: false, public?: true
    attribute :delivery_fee, :money, allow_nil?: false, public?: true
    attribute :tip, :money, allow_nil?: false, public?: true
    attribute :total, :money, allow_nil?: false, public?: true

    attribute :contact, :map, allow_nil?: false, public?: true
    attribute :scheduled_for, :utc_datetime_usec, public?: true
    attribute :idempotency_key, :string, allow_nil?: false, public?: true
    attribute :external_ref, :string, public?: true

    attribute :tracking_key, :uuid_v7 do
      allow_nil? false
      public? true
      writable? false
      default &Ash.UUIDv7.generate/0
    end

    timestamps()
  end

  relationships do
    belongs_to :cart, EatsbotCore.Carts.Cart, allow_nil?: true, public?: true
    has_many :lines, EatsbotCore.Orders.OrderLine, public?: true

    has_many :state_changes, EatsbotCore.Orders.OrderStateChange do
      public? true
      sort sequence: :asc
    end

    has_one :delivery, EatsbotCore.Deliveries.Delivery do
      public? true
      destination_attribute :order_id
    end
  end

  identities do
    identity :unique_cart, [:cart_id]
    identity :unique_idempotency, [:channel, :idempotency_key]
    identity :unique_external, [:channel, :external_ref]
    identity :unique_tracking_key, [:tracking_key]
  end
end
