defmodule RestaurantCore.Coupling do
  @moduledoc """
  I8 as data: which (order state, handoff view) pairs may coexist, and the only
  joint steps between them. Literal and call-free; `RestaurantCore.Delivery`
  runs the reducers a row names and admits only the row's target.

  A delivery order's handoff is a `FulfillmentCore` state, seen through
  `view/1` as one of 13 views (`:none` when transport was never requested).
  19 of the 104 delivery pairs are coupled; pickup and dine-in orders couple
  only with `:none`.

  Each row is `{from, owner, op, to, order_effect}`:

    * the restaurant takes the kitchen's steps (`{:kitchen, action}`, through
      `Kitchen.apply/3`), requests transport (`:request`) and withdraws its
      request (`:withdraw`, FulfillmentCore's commerce cancel);
    * Dispatch takes `{:dispatch, op}`, FulfillmentCore's dispatch ops.

  `order_effect` is `:kitchen`, `:hold` or `:transport`
  (`OrderCore.Transport` to `transport_target/1`). Dispatch never takes an
  order-owned edge and the restaurant never takes a delivery-owned one: the
  order cancel is always the kitchen's own step, admitted only once transport is
  no longer live (`live/0`), i.e. after Dispatch has confirmed a withdrawal,
  rejected, failed before pickup, or never accepted a withdrawn request.

  `strict/0` names the cells the pinned reducers would accept but admission
  refuses, with the refusal. Each is a loosening for later that rejects no
  admitted history.
  """

  @states ~w(placed accepted preparing ready dispatched completed cancelled failed)a
  @views ~w(none requested accepted in_transit withdrawn cancel_pending cancel_in_transit
            rejected cancelled cancelled_in_transit delivered failed_before_pickup failed_in_transit)a

  @live ~w(requested accepted cancel_pending)a
  @requestable ~w(none rejected cancelled failed_before_pickup)a

  @simple [
    placed: :none,
    accepted: :none,
    preparing: :none,
    ready: :none,
    completed: :none,
    cancelled: :none
  ]

  @rows [
    {{:placed, :none}, :restaurant, {:kitchen, :accept}, {:accepted, :none}, :kitchen},
    {{:accepted, :none}, :restaurant, {:kitchen, :start_preparing}, {:preparing, :none},
     :kitchen},
    {{:preparing, :none}, :restaurant, {:kitchen, :mark_ready}, {:ready, :none}, :kitchen},
    {{:placed, :none}, :restaurant, {:kitchen, :cancel}, {:cancelled, :none}, :kitchen},
    {{:accepted, :none}, :restaurant, {:kitchen, :cancel}, {:cancelled, :none}, :kitchen},
    {{:preparing, :none}, :restaurant, {:kitchen, :cancel}, {:cancelled, :none}, :kitchen},
    {{:ready, :none}, :restaurant, {:kitchen, :cancel}, {:cancelled, :none}, :kitchen},
    {{:ready, :withdrawn}, :restaurant, {:kitchen, :cancel}, {:cancelled, :withdrawn}, :kitchen},
    {{:ready, :rejected}, :restaurant, {:kitchen, :cancel}, {:cancelled, :rejected}, :kitchen},
    {{:ready, :cancelled}, :restaurant, {:kitchen, :cancel}, {:cancelled, :cancelled}, :kitchen},
    {{:ready, :failed_before_pickup}, :restaurant, {:kitchen, :cancel},
     {:cancelled, :failed_before_pickup}, :kitchen},
    {{:ready, :none}, :restaurant, :request, {:ready, :requested}, :hold},
    {{:ready, :rejected}, :restaurant, :request, {:ready, :requested}, :hold},
    {{:ready, :cancelled}, :restaurant, :request, {:ready, :requested}, :hold},
    {{:ready, :failed_before_pickup}, :restaurant, :request, {:ready, :requested}, :hold},
    {{:ready, :requested}, :restaurant, :withdraw, {:ready, :withdrawn}, :hold},
    {{:ready, :accepted}, :restaurant, :withdraw, {:ready, :cancel_pending}, :hold},
    {{:ready, :requested}, :dispatch, {:dispatch, :accept}, {:ready, :accepted}, :hold},
    {{:ready, :withdrawn}, :dispatch, {:dispatch, :accept}, {:ready, :cancel_pending}, :hold},
    {{:ready, :requested}, :dispatch, {:dispatch, :reject}, {:ready, :rejected}, :hold},
    {{:ready, :withdrawn}, :dispatch, {:dispatch, :reject}, {:ready, :rejected}, :hold},
    {{:cancelled, :withdrawn}, :dispatch, {:dispatch, :reject}, {:cancelled, :rejected}, :hold},
    {{:ready, :withdrawn}, :dispatch, {:dispatch, :cancel_confirmed}, {:ready, :cancelled},
     :hold},
    {{:ready, :cancel_pending}, :dispatch, {:dispatch, :cancel_confirmed}, {:ready, :cancelled},
     :hold},
    {{:cancelled, :withdrawn}, :dispatch, {:dispatch, :cancel_confirmed},
     {:cancelled, :cancelled}, :hold},
    {{:ready, :accepted}, :dispatch, {:dispatch, :in_transit}, {:dispatched, :in_transit},
     :transport},
    {{:dispatched, :in_transit}, :dispatch, {:dispatch, :delivered}, {:completed, :delivered},
     :transport},
    {{:ready, :accepted}, :dispatch, {:dispatch, :failed}, {:ready, :failed_before_pickup},
     :hold},
    {{:ready, :cancel_pending}, :dispatch, {:dispatch, :failed}, {:ready, :failed_before_pickup},
     :hold},
    {{:dispatched, :in_transit}, :dispatch, {:dispatch, :failed}, {:failed, :failed_in_transit},
     :transport}
  ]

  @delivery @rows |> Enum.flat_map(fn {from, _, _, to, _} -> [from, to] end) |> Enum.uniq()
  @index Map.new(@rows, fn {from, _, op, _, _} = row -> {{from, op}, row} end)

  @strict %{
    {{:ready, :requested}, {:kitchen, :cancel}} => :transport_pending,
    {{:ready, :accepted}, {:kitchen, :cancel}} => :transport_pending,
    {{:ready, :cancel_pending}, {:kitchen, :cancel}} => :transport_pending,
    {{:dispatched, :in_transit}, :withdraw} => :transport_started,
    {{:ready, :cancel_pending}, {:dispatch, :in_transit}} => :cancel_pending,
    {{:cancelled, :withdrawn}, {:dispatch, :accept}} => :order_cancelled
  }

  @fields %{
    "accept" => {:accept, ["transport_ref"]},
    "reject" => {:reject, ["reason"]},
    "in_transit" => {:in_transit, []},
    "delivered" => {:delivered, ["proof"]},
    "failed" => {:failed, ["proof", "reason"]},
    "cancel_confirmed" => {:cancel_confirmed, []}
  }

  def states, do: @states
  def views, do: @views
  @doc "Views in which Dispatch may still commit or has committed a driver before pickup."
  def live, do: @live
  @doc "Views from which a ready delivery order may request transport (again)."
  def requestable, do: @requestable
  def rows, do: @rows
  def strict, do: @strict

  @doc "The handoff view of a FulfillmentCore state, or `:none` for no handoff."
  def view(nil), do: :none

  def view(%{phase: phase})
      when phase in [:requested, :accepted, :in_transit, :rejected, :delivered], do: phase

  def view(%{phase: :cancel_requested, transport_ref: nil}), do: :withdrawn
  def view(%{phase: :cancel_requested, transport_started: false}), do: :cancel_pending
  def view(%{phase: :cancel_requested, transport_started: true}), do: :cancel_in_transit
  def view(%{phase: :cancelled, transport_started: false}), do: :cancelled
  def view(%{phase: :cancelled, transport_started: true}), do: :cancelled_in_transit
  def view(%{phase: :failed, transport_started: false}), do: :failed_before_pickup
  def view(%{phase: :failed, transport_started: true}), do: :failed_in_transit

  def coupled?(:delivery, state, view), do: {state, view} in @delivery
  def coupled?(_fulfillment, state, view), do: {state, view} in @simple

  @doc "The row for a step from a delivery pair."
  def row(from, op), do: Map.fetch(@index, {from, op})

  @doc "A Dispatch op's name, its atom and the exact optional fields it carries."
  def dispatch_fields(name) do
    case Map.fetch(@fields, name) do
      {:ok, {op, fields}} -> {:ok, op, fields}
      :error -> :error
    end
  end

  def transport_target(:in_transit), do: :dispatched
  def transport_target(:delivered), do: :completed
  def transport_target(:failed), do: :failed
end
