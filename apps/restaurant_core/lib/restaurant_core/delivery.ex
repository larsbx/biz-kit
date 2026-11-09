defmodule RestaurantCore.Delivery do
  @moduledoc """
  Restaurant's projection of Dispatch-attested fulfillment. The restaurant
  offers one handoff when its delivery order is ready. Dispatch owns the
  transport and explicitly attests to pickup and delivery evidence; only
  those admitted events can advance the restaurant's delivery lifecycle.
  """

  alias RestaurantCore.Kitchen

  @mode "dispatch"
  @operations %{"accept" => :accept, "picked_up" => :in_transit, "delivered" => :delivered}
  @targets %{in_transit: :dispatched, delivered: :completed}

  def init, do: %{handoffs: %{}, loads: %{}, proofs: %{}}

  def handoff(delivery, chapter, merchant, order_id),
    do: delivery.handoffs[{chapter, merchant, order_id}]

  def uuid?(value),
    do:
      is_binary(value) and
        Regex.match?(~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/, value)

  def apply(delivery, chapter, merchant, %{fulfillment: :delivery, id: id} = order, p) do
    key = {chapter, merchant, id}
    load = {chapter, p["tenant_id"], p["load_id"]}
    proof = {chapter, p["tenant_id"], p["proof_id"]}

    with {:ok, operation} <- Map.fetch(@operations, p["op"]),
         :ok <- evidence(operation, p),
         {:ok, prior} <- current(delivery.handoffs[key], order),
         :ok <- bind_load(delivery, key, load, prior, operation, p["assignment_id"]),
         command = command(p, operation),
         {:ok, updated, :accepted} <- FulfillmentCore.apply(prior, merchant, :dispatch, command),
         :ok <- unused_proof(delivery, proof, operation),
         {:ok, order} <- mirror(order, operation) do
      updated = Map.put(updated, :dispatch_assignment, p["assignment_id"])

      updated_delivery =
        delivery
        |> put_in([:handoffs, key], updated)
        |> put_in([:loads, load], key)

      updated_delivery =
        if operation == :accept,
          do: updated_delivery,
          else: put_in(updated_delivery, [:proofs, proof], key)

      {:ok, updated_delivery, order}
    else
      {:ok, _, :duplicate} -> {:error, :duplicate_delivery_step}
      {:error, _} = error -> error
      :error -> {:error, :unsupported_delivery_operation}
    end
  end

  def apply(_, _, _, _, _), do: {:error, :delivery_order_required}

  defp current(nil, %{state: :ready} = order),
    do: FulfillmentCore.new(order.merchant, order.id, order.id, @mode)

  defp current(nil, _), do: {:error, :delivery_order_not_ready}
  defp current(handoff, _), do: {:ok, handoff}

  defp bind_load(delivery, key, {_, _, load_id} = load, prior, operation, assignment) do
    case {Map.get(delivery.loads, load), prior} do
      {^key, %{transport_ref: ^load_id, dispatch_assignment: ^assignment}} -> :ok
      {nil, %{transport_ref: nil}} when operation == :accept -> :ok
      _ -> {:error, :wrong_delivery_transport}
    end
  end

  defp evidence(operation, p) do
    valid_proof? =
      if operation == :accept,
        do: not Map.has_key?(p, "proof_id"),
        else: uuid?(p["proof_id"])

    if Enum.all?(~w(load_id tenant_id assignment_id), &uuid?(p[&1])) and valid_proof?,
      do: :ok,
      else: {:error, :invalid_dispatch_evidence}
  end

  defp command(p, operation) do
    %{
      id: p["command_id"],
      expected_version: p["expected_version"],
      op: operation,
      transport_ref: p["load_id"],
      assignment_ref: p["assignment_id"],
      proof_ref: p["proof_id"]
    }
  end

  defp unused_proof(_delivery, _proof, :accept), do: :ok

  defp unused_proof(delivery, proof, _) do
    if Map.has_key?(delivery.proofs, proof),
      do: {:error, :dispatch_proof_already_used},
      else: :ok
  end

  defp mirror(%{state: :ready} = order, :accept), do: {:ok, order}
  defp mirror(_, :accept), do: {:error, :delivery_order_not_ready}

  defp mirror(order, operation) do
    target = Map.fetch!(@targets, operation)

    if Kitchen.legal?(:delivery, order.state, target),
      do: {:ok, %{order | state: target, version: order.version + 1}},
      else: {:error, :invalid_delivery_order_transition}
  end
end
