defmodule EatsbotCore.Orders.OrderStateChange do
  @moduledoc """
  Append-only history of an order's transitions (I₆). Replaying it with
  `EatsbotCore.Orders.Transitions.replay/2` yields the order's current state.

  There is no update or destroy action, and rows are only written by
  `EatsbotCore.Orders.Transition` inside the transition's transaction.
  """
  use Ash.Resource,
    otp_app: :eatsbot,
    domain: EatsbotCore.Orders,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias EatsbotCore.Orders.{ActorIn, Transitions}

  postgres do
    table "order_state_changes"
    repo Eatsbot.Repo

    references do
      reference :order, on_delete: :delete
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if {ActorIn, levels: [:admin, :staff, :system]}
    end

    policy action_type(:create) do
      description "only EatsbotCore.Orders.Transition writes history, as the system actor"
      authorize_if {ActorIn, levels: [:system]}
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :sequence, :integer do
      allow_nil? false
      public? true
      constraints min: 1
    end

    attribute :from, :atom do
      allow_nil? false
      public? true
      constraints one_of: Transitions.states()
    end

    attribute :to, :atom do
      allow_nil? false
      public? true
      constraints one_of: Transitions.states()
    end

    attribute :actor_type, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:customer, :staff, :system, :aggregator]
    end

    attribute :reason, :string, public?: true

    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :order, EatsbotCore.Orders.Order, allow_nil?: false
  end

  actions do
    defaults [:read]

    create :record do
      accept [:order_id, :sequence, :from, :to, :reason, :actor_type]
    end

    read :for_order do
      argument :order_id, :uuid, allow_nil?: false
      filter expr(order_id == ^arg(:order_id))
    end
  end

  identities do
    identity :unique_sequence, [:order_id, :sequence]
  end
end
