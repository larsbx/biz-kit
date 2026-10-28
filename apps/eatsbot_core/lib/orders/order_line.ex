defmodule EatsbotCore.Orders.OrderLine do
  @moduledoc """
  A line of an order, copied from the cart at checkout (I₁).

  The resource has no update or destroy action, so a line cannot change after the
  order is placed; corrections are refunds. `variant_id` is kept for reporting and
  may be nil for lines imported from a marketplace without a menu mapping.
  """
  use Ash.Resource,
    otp_app: :eatsbot,
    domain: EatsbotCore.Orders,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias EatsbotCore.Orders.ActorIn

  postgres do
    table "order_lines"
    repo Eatsbot.Repo

    references do
      reference :order, on_delete: :delete
      reference :variant, on_delete: :nilify
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if {ActorIn, levels: [:admin, :staff, :system]}
    end

    policy action_type(:create) do
      description "lines are only created by Order.place, as the system actor"
      authorize_if {ActorIn, levels: [:system]}
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :name, :string, allow_nil?: false, public?: true
    attribute :options, :map, allow_nil?: false, public?: true, default: %{}

    attribute :quantity, :integer do
      allow_nil? false
      public? true
      constraints min: 1
    end

    attribute :unit_price, :money, allow_nil?: false, public?: true
    attribute :discount, :money, allow_nil?: false, public?: true
    attribute :subtotal, :money, allow_nil?: false, public?: true
    attribute :notes, :string, public?: true

    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :order, EatsbotCore.Orders.Order, allow_nil?: false
    belongs_to :variant, EatsbotCore.Products.Variant, allow_nil?: true, public?: true
  end

  actions do
    defaults [:read]

    create :snapshot do
      primary? true
      accept [:variant_id, :name, :options, :quantity, :unit_price, :discount, :subtotal, :notes]
    end
  end
end
