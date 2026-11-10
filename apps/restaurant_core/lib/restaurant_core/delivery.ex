defmodule RestaurantCore.Delivery do
  @moduledoc """
  The delivery handoff's composition: for each restaurant or Dispatch fact, run
  only the reducers its `RestaurantCore.Coupling` row names, then refuse unless
  the resulting (order state, handoff view) pair is the row's target.

  The only caller of `FulfillmentCore` and `OrderCore.Transport`. Pure; who
  signed and with which grant is `RestaurantCore.Admission`'s question.
  """

  alias OrderCore.Transport
  alias RestaurantCore.{Coupling, Kitchen}

  @mode "restaurant-courier"

  @doc "An order's (state, handoff view) pair; `handoff` may be nil."
  def pair(order, handoff), do: {order.state, Coupling.view(handoff && handoff.fc)}

  @doc "Judge a kitchen step `Kitchen.apply/3` accepted, taking `order` to `next`."
  def guard_step(order, next, handoff, action) do
    from = pair(order, handoff)
    to = pair(next, handoff)

    if order.fulfillment == :delivery,
      do: judge(from, {:kitchen, action}, to),
      else: coupled(order, from) |> then(&if(&1 == :ok, do: coupled(next, to), else: &1))
  end

  @doc "A new FulfillmentCore request for a ready delivery order whose transport is not live."
  def request(order, handoff, request_id) do
    from = pair(order, handoff)

    with :ok <- coupled(order, from),
         :ok <- if(order.state == :ready, do: :ok, else: {:error, :order_not_ready}),
         :ok <-
           if(elem(from, 1) in Coupling.requestable(),
             do: :ok,
             else: {:error, :transport_already_requested}
           ),
         {:ok, fc} <- FulfillmentCore.new(order.merchant, request_id, order.id, @mode),
         :ok <- judge(from, :request, pair(order, %{fc: fc})) do
      {:ok, fc}
    end
  end

  @doc "The restaurant withdraws its request: FulfillmentCore's commerce cancel; the order holds."
  def withdraw(order, handoff, event) do
    from = pair(order, handoff)

    with :ok <- coupled(order, from),
         {:ok, fc} <- fc_apply(handoff.fc, order.merchant, :commerce, event, :duplicate_command),
         :ok <- judge(from, :withdraw, pair(order, %{fc: fc})) do
      {:ok, fc}
    end
  end

  @doc "A Dispatch step: FulfillmentCore's dispatch op, then the row's order effect."
  def dispatch(order, handoff, principal, %{op: op} = event) do
    from = pair(order, handoff)

    with :ok <- coupled(order, from),
         {:ok, fc} <-
           fc_apply(handoff.fc, order.merchant, :dispatch, event, :duplicate_transport_step),
         {:ok, row} <- row(from, {:dispatch, op}),
         {:ok, next} <- effect(row, order, principal, event),
         :ok <- judge(from, {:dispatch, op}, pair(next, %{fc: fc})) do
      {:ok, next, fc}
    end
  end

  defp effect({_, _, _, _, :hold}, order, _, _), do: {:ok, order}

  defp effect({_, _, {:dispatch, op}, _, :transport}, order, principal, event) do
    trusted = %{
      transport: true,
      principal: principal,
      merchant: order.merchant,
      order_id: order.id
    }

    cmd = %{
      id: event.id,
      expected_version: order.version,
      to: Coupling.transport_target(op),
      reason: Map.get(event, :reason)
    }

    case Transport.apply(Kitchen.workflow(), order, trusted, cmd) do
      {:ok, next, :accepted} -> {:ok, next}
      {:ok, _, :duplicate} -> {:error, :inconsistent_handoff}
      error -> error
    end
  end

  defp fc_apply(fc, merchant, actor, event, duplicate) do
    case FulfillmentCore.apply(fc, merchant, actor, event) do
      {:ok, next, :accepted} -> {:ok, next}
      {:ok, _, :duplicate} -> {:error, {duplicate, event.id}}
      error -> error
    end
  end

  defp coupled(%{fulfillment: f}, {s, v}),
    do: if(Coupling.coupled?(f, s, v), do: :ok, else: {:error, :inconsistent_handoff})

  defp row(from, op) do
    case Coupling.row(from, op) do
      {:ok, row} -> {:ok, row}
      :error -> {:error, Map.get(Coupling.strict(), {from, op}, :inconsistent_handoff)}
    end
  end

  defp judge(from, op, to) do
    case row(from, op) do
      {:ok, {_, _, _, ^to, _}} -> :ok
      {:ok, _} -> {:error, :inconsistent_handoff}
      error -> error
    end
  end
end
