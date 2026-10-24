defmodule FulfillmentCore do
  @moduledoc """
  Pure cross-domain fulfillment handoff protocol and replay state machine.

  Commerce owns order/payment/kitchen facts. Dispatch owns transport
  assignment/movement/proof. This module only validates immutable request
  references and subsequent accepted acknowledgments; it performs no I/O.
  """

  @terminal [:rejected, :cancelled, :delivered, :failed]

  @doc "Initialize a request using opaque identifiers, not delivery PII."
  def new(merchant, request_id, order_id, mode)
      when is_binary(merchant) and byte_size(merchant) > 0 and
             is_binary(request_id) and byte_size(request_id) > 0 and
             is_binary(order_id) and byte_size(order_id) > 0 and
             is_binary(mode) and byte_size(mode) > 0 do
    {:ok,
     %{
       merchant: merchant,
       request_id: request_id,
       order_id: order_id,
       mode: mode,
       phase: :requested,
       transport_ref: nil,
       proof_ref: nil,
       transport_started: false,
       version: 0,
       seen: %{}
     }}
  end

  def new(_, _, _, _), do: {:error, :invalid_fulfillment_request}

  @doc """
  Validate an accepted typed event. The host must authenticate and authorize
  the producer, serialize append, enforce unique request ID and persist facts.
  """
  def apply(state, merchant, actor, %{id: id, expected_version: revision, op: _} = event) do
    with :ok <- scope(state, merchant), :ok <- identifier(id) do
      case Map.get(state.seen, id) do
        {^actor, ^event} ->
          {:ok, state, :duplicate}

        nil ->
          with :ok <- version(state.version, revision),
               {:ok, updated} <- transition(state, actor, event) do
            {:ok,
             %{
               updated
               | version: state.version + 1,
                 seen: Map.put(state.seen, id, {actor, event})
             }, :accepted}
          end

        _ ->
          {:error, :idempotency_conflict}
      end
    end
  end

  def apply(_, _, _, _), do: {:error, :invalid_fulfillment_event}

  @doc "Deterministically fold events with their authenticated producer classes."
  def replay(initial, merchant, steps) when is_list(steps) do
    Enum.reduce_while(steps, {:ok, initial}, fn {actor, event}, {:ok, state} ->
      case apply(state, merchant, actor, event) do
        {:ok, updated, _} -> {:cont, {:ok, updated}}
        error -> {:halt, error}
      end
    end)
  end

  def replay(_, _, _), do: {:error, :invalid_steps}

  @doc "Identify a handoff still awaiting transport resolution."
  def pending?(%{phase: phase}),
    do: phase in [:requested, :accepted, :cancel_requested, :in_transit]

  defp scope(%{merchant: expected}, merchant) when expected == merchant, do: :ok
  defp scope(%{merchant: _}, _), do: {:error, :wrong_merchant}
  defp scope(_, _), do: {:error, :invalid_state}
  defp version(n, n), do: :ok
  defp version(_, _), do: {:error, :stale_fulfillment_version}

  defp identifier(v) when is_binary(v) and byte_size(v) in 1..128, do: :ok
  defp identifier(_), do: {:error, :invalid_reference}

  defp transition(state, :dispatch, %{op: :accept, transport_ref: reference}) do
    with :ok <- phase(state, [:requested, :cancel_requested]),
         :ok <- no_transport_ref(state),
         :ok <- identifier(reference) do
      next = if state.phase == :cancel_requested, do: :cancel_requested, else: :accepted
      {:ok, %{state | phase: next, transport_ref: reference}}
    end
  end

  defp transition(state, :dispatch, %{op: :reject, reason: reason}) do
    with :ok <- phase(state, [:requested, :cancel_requested]),
         :ok <- no_transport_ref(state),
         :ok <- identifier(reason) do
      {:ok, %{state | phase: :rejected}}
    end
  end

  defp transition(state, :commerce, %{op: :cancel}) do
    with :ok <- phase(state, [:requested, :accepted, :in_transit]) do
      {:ok, %{state | phase: :cancel_requested}}
    end
  end

  defp transition(state, :dispatch, %{op: :cancel_confirmed}) do
    with :ok <- phase(state, [:cancel_requested]) do
      {:ok, %{state | phase: :cancelled}}
    end
  end

  defp transition(state, :dispatch, %{op: :in_transit}) do
    with :ok <- phase(state, [:accepted, :cancel_requested]),
         :ok <- has_transport_ref(state) do
      next = if state.phase == :cancel_requested, do: :cancel_requested, else: :in_transit
      {:ok, %{state | phase: next, transport_started: true}}
    end
  end

  defp transition(state, :dispatch, %{op: :delivered, proof_ref: proof}) do
    with :ok <- phase(state, [:in_transit, :cancel_requested]),
         :ok <- has_started_transport(state),
         :ok <- identifier(proof) do
      {:ok, %{state | phase: :delivered, proof_ref: proof}}
    end
  end

  defp transition(state, :dispatch, %{op: :failed, reason: reason}) do
    with :ok <- phase(state, [:accepted, :in_transit, :cancel_requested]),
         :ok <- has_transport_ref(state),
         :ok <- identifier(reason) do
      {:ok, %{state | phase: :failed}}
    end
  end

  defp transition(_, _, _), do: {:error, :wrong_event_authority}

  defp no_transport_ref(%{transport_ref: nil}), do: :ok
  defp no_transport_ref(_), do: {:error, :transport_already_accepted}

  defp has_transport_ref(%{transport_ref: ref}) when is_binary(ref), do: :ok
  defp has_transport_ref(_), do: {:error, :transport_not_accepted}

  defp has_started_transport(%{transport_started: true}), do: :ok
  defp has_started_transport(_), do: {:error, :delivery_without_transport_start}

  defp phase(state, allowed) do
    cond do
      state.phase in @terminal -> {:error, :terminal_fulfillment}
      state.phase in allowed -> :ok
      true -> {:error, :invalid_fulfillment_transition}
    end
  end
end
