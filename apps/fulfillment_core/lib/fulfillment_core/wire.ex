defmodule FulfillmentCore.Wire do
  @moduledoc """
  Exact-shape v1 transport event contract for independently deployed clients.

  Only a verified *host* can determine merchant, request ID and producer.
  Parsing is not a grant, append, proof verification or driver assignment.
  """
  @schema "bizkit.fulfillment.event.v1"
  @max_int 9_007_199_254_740_991
  @base ~w(schema merchant request_id id expected_version op)
  @ops %{
    "accept" => {:dispatch, :accept, ["transport_ref"]},
    "reject" => {:dispatch, :reject, ["reason"]},
    "cancel" => {:commerce, :cancel, []},
    "cancel_confirmed" => {:dispatch, :cancel_confirmed, []},
    "in_transit" => {:dispatch, :in_transit, []},
    "delivered" => {:dispatch, :delivered, ["proof_ref"]},
    "failed" => {:dispatch, :failed, ["reason"]}
  }

  @doc "Decode a JSON map against a trusted host binding, not a claimed wire actor."
  def decode(%{} = wire, %{merchant: merchant, request_id: request_id, producer: actor})
      when actor in [:commerce, :dispatch] do
    with :ok <- bound?(wire, merchant, request_id),
         {:ok, {^actor, op, fields}} <- permitted(actor, Map.get(wire, "op")),
         :ok <- shape(wire, fields),
         :ok <- values(wire, fields) do
      data =
        (fields ++ ["id", "expected_version"])
        |> Map.new(fn key -> {field(key), Map.fetch!(wire, key)} end)
        |> Map.put(:op, op)

      {:ok, actor, data}
    end
  end

  def decode(_, _), do: {:error, :invalid_fulfillment_event}

  defp bound?(wire, merchant, request_id) do
    if identifier(merchant) and identifier(request_id) and
         Map.get(wire, "merchant") === merchant and
         Map.get(wire, "request_id") === request_id,
      do: :ok,
      else: {:error, :wrong_fulfillment_scope}
  end

  defp permitted(actor, operation) do
    case Map.fetch(@ops, operation) do
      {:ok, {^actor, _, _} = allowed} -> {:ok, allowed}
      {:ok, _} -> {:error, :wrong_event_authority}
      :error -> {:error, :unsupported_fulfillment_operation}
    end
  end

  defp shape(wire, fields) do
    if wire["schema"] == @schema and
         Enum.sort(Map.keys(wire)) == Enum.sort(@base ++ fields),
      do: :ok,
      else: {:error, :invalid_fulfillment_shape}
  end

  defp values(wire, fields) do
    version = Map.get(wire, "expected_version")

    if Enum.all?(["id" | fields], &identifier(Map.get(wire, &1))) and
         is_integer(version) and version >= 0 and version <= @max_int,
      do: :ok,
      else: {:error, :invalid_fulfillment_value}
  end

  defp identifier(value), do: is_binary(value) and byte_size(value) in 1..128

  # Never invoke String.to_atom on user JSON.
  defp field("id"), do: :id
  defp field("expected_version"), do: :expected_version
  defp field("transport_ref"), do: :transport_ref
  defp field("proof_ref"), do: :proof_ref
  defp field("reason"), do: :reason
end
