defmodule DispatchCore.LastMile do
  @moduledoc """
  Source-scoped, pure last-mile event and evidence policy derived from
  Eatsbot's delivery transitions and order/delivery edge ownership.

  This is a **candidate** projection only. It does not assign drivers, verify
  signatures/GPS, custody evidence, emit a signed business event, authorize
  actual delivery or claim financial settlement. The operational writer is
  biz-kit's Dispatch; FulfillmentCore owns cross-domain handoff.

  Cancellation intent does not erase physical pickup or late delivery proof.
  An observer can mark an unresolved attempt held without fabricating a
  terminal failure. The host must authenticate actual producers and
  independently validate the evidence refs.
  """

  @terminal [:delivered, :cancelled]

  def new(merchant, delivery_id) do
    with :ok <- reference(merchant),
         :ok <- reference(delivery_id) do
      {:ok,
       %{
         merchant: merchant,
         delivery_id: delivery_id,
         phase: :awaiting_ready,
         pickup_ref: nil,
         delivery_proof_ref: nil,
         exception_ref: nil,
         cancel_requested?: false,
         held?: false,
         version: 0,
         seen: %{}
       }}
    end
  end

  @doc "The host must authenticate producer and admit any resulting event."
  def apply(state, merchant, producer, %{id: id, expected_version: revision} = event) do
    with :ok <- scope(state, merchant),
         :ok <- reference(id) do
      case Map.fetch(state.seen, id) do
        {:ok, {^producer, ^event}} ->
          {:ok, state, :duplicate}

        {:ok, _} ->
          {:error, :idempotency_conflict}

        :error ->
          with :ok <- version(state.version, revision),
               {:ok, next} <- transition(state, producer, event) do
            {:ok,
             %{
               next
               | version: state.version + 1,
                 seen: Map.put(state.seen, id, {producer, event})
             }, :accepted}
          end
      end
    end
  end

  def apply(_, _, _, _), do: {:error, :invalid_last_mile_event}

  def replay(initial, merchant, steps) when is_list(steps) do
    Enum.reduce_while(steps, {:ok, initial}, fn
      {producer, event}, {:ok, state} ->
        case apply(state, merchant, producer, event) do
          {:ok, next, _} -> {:cont, {:ok, next}}
          error -> {:halt, error}
        end

      _, _ ->
        {:halt, {:error, :invalid_steps}}
    end)
  end

  def replay(_, _, _), do: {:error, :invalid_steps}

  def pending?(%{phase: phase}), do: phase not in @terminal

  defp transition(%{phase: :awaiting_ready} = state, :commerce, %{op: :ready}) do
    {:ok, %{state | phase: :ready_for_pickup}}
  end

  defp transition(
         %{phase: :ready_for_pickup} = state,
         :dispatch,
         %{op: :picked_up, pickup_ref: proof}
       ) do
    with :ok <- reference(proof) do
      {:ok, %{state | phase: :in_transit, pickup_ref: proof}}
    end
  end

  defp transition(
         %{phase: :in_transit} = state,
         :dispatch,
         %{op: :exception, reason_ref: proof}
       ) do
    with :ok <- reference(proof) do
      {:ok, %{state | phase: :exception, exception_ref: proof}}
    end
  end

  defp transition(
         %{phase: :exception} = state,
         :dispatch,
         %{op: :resolved, resolution_ref: proof}
       ) do
    with :ok <- reference(proof) do
      {:ok, %{state | phase: :in_transit, exception_ref: proof}}
    end
  end

  defp transition(
         %{phase: :in_transit} = state,
         :dispatch,
         %{op: :delivered, delivery_proof_ref: proof}
       ) do
    with :ok <- reference(proof) do
      {:ok, %{state | phase: :delivered, delivery_proof_ref: proof}}
    end
  end

  defp transition(%{phase: phase, cancel_requested?: false} = state, :commerce, %{op: :cancel})
       when phase not in @terminal do
    {:ok, %{state | cancel_requested?: true}}
  end

  defp transition(%{cancel_requested?: true, phase: phase} = state, :dispatch, %{
         op: :cancel_confirmed
       })
       when phase in [:awaiting_ready, :ready_for_pickup] do
    {:ok, %{state | phase: :cancelled}}
  end

  defp transition(%{phase: phase} = state, :observer, %{op: :uncertain})
       when phase not in @terminal do
    {:ok, %{state | held?: true}}
  end

  defp transition(%{phase: phase}, _, _) when phase in @terminal,
    do: {:error, :terminal_delivery}

  defp transition(%{phase: :in_transit}, :dispatch, %{op: :cancel_confirmed}),
    do: {:error, :requires_transport_resolution}

  defp transition(_, _, _), do: {:error, :invalid_transition_or_authority}

  defp scope(%{merchant: owner}, owner), do: :ok
  defp scope(%{merchant: _}, _), do: {:error, :wrong_merchant}
  defp scope(_, _), do: {:error, :invalid_state}

  defp version(v, v), do: :ok
  defp version(_, _), do: {:error, :stale_last_mile_version}

  defp reference(value) when is_binary(value) and byte_size(value) in 1..128, do: :ok
  defp reference(_), do: {:error, :invalid_reference}
end
