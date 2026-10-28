defmodule BizKit.LastMileBridge do
  @moduledoc """
  Pure pre-admission handoff from DispatchCore.LastMile to FulfillmentCore.

  Dispatch owns transport and independently verified physical evidence.
  Commerce owns the order and cancellation intent. FulfillmentCore owns the
  cross-domain handoff contract. This bridge can propose a compatible event,
  but it cannot authenticate a Dispatch producer, create a durable ledger
  event or claim that an opaque proof reference is genuine.

  A cancellation race is never resolved by fabricating success or abort:
  a delivered transport observation while a fulfillment cancel is pending
  remains an explicit reconciliation blocker until the owner adjudicates it.
  """

  alias FulfillmentCore, as: Fulfillment

  @doc """
  Propose an immutable FulfillmentCore event from a trusted DispatchCore
  snapshot. The trusted context must be constructed by a host that verified
  source grants, exact transport version, physical proof and event identity.
  """
  def preview(fulfillment, last_mile, trusted)
      when is_map(fulfillment) and is_map(last_mile) and is_map(trusted) do
    with :ok <- bind(fulfillment, last_mile, trusted),
         {:ok, event} <- candidate(fulfillment, last_mile, trusted),
         {:ok, result, :accepted} <-
           Fulfillment.apply(fulfillment, trusted.merchant, :dispatch, event) do
      {:ok,
       %{
         kind: :unsigned_fulfillment_candidate,
         merchant: trusted.merchant,
         transport_ref: trusted.verified_transport_ref,
         source_last_mile_version: last_mile.version,
         source_event_id: trusted.event_id,
         fulfillment_event: event,
         resulting_phase: result.phase
       }}
    else
      {:ok, _, :duplicate} -> {:error, :already_proposed}
      {:error, _} = error -> error
    end
  end

  def preview(_, _, _), do: {:error, :invalid_last_mile_proposal}

  defp bind(fulfillment, last_mile, trusted) do
    merchant = Map.get(trusted, :merchant)
    ref = Map.get(trusted, :verified_transport_ref)

    cond do
      not valid_ref?(merchant) or not valid_ref?(ref) or
          not valid_ref?(Map.get(trusted, :event_id)) ->
        {:error, :invalid_trusted_transport_binding}

      Map.get(trusted, :verified_source) !== :dispatch ->
        {:error, :unverified_transport_source}

      Map.get(fulfillment, :merchant) !== merchant or
        Map.get(last_mile, :merchant) !== merchant or
        Map.get(fulfillment, :transport_ref) !== ref or
          Map.get(last_mile, :delivery_id) !== ref ->
        {:error, :wrong_transport_scope}

      not is_integer(Map.get(last_mile, :version)) or
          Map.get(trusted, :last_mile_version) !== last_mile.version ->
        {:error, :stale_transport_version}

      not is_integer(Map.get(fulfillment, :version)) ->
        {:error, :invalid_fulfillment_state}

      true ->
        :ok
    end
  end

  defp candidate(
         %{phase: :accepted} = fulfillment,
         %{phase: :in_transit, pickup_ref: ref},
         trusted
       ) do
    if valid_ref?(ref) and Map.get(trusted, :verified_pickup_ref) === ref do
      {:ok, event(fulfillment, trusted, :in_transit)}
    else
      {:error, :unverified_pickup_proof}
    end
  end

  defp candidate(
         %{phase: :in_transit} = fulfillment,
         %{phase: :delivered, delivery_proof_ref: ref},
         trusted
       ) do
    if valid_ref?(ref) and Map.get(trusted, :verified_delivery_proof_ref) === ref do
      {:ok, event(fulfillment, trusted, :delivered, %{proof_ref: ref})}
    else
      {:error, :unverified_delivery_proof}
    end
  end

  defp candidate(%{phase: :cancel_requested}, %{phase: :delivered}, _),
    do: {:error, :pending_cancellation_reconciliation}

  defp candidate(_, _, _), do: {:error, :no_corresponding_fulfillment_transition}

  defp event(fulfillment, trusted, op, extras \\ %{}) do
    Map.merge(
      %{
        id: trusted.event_id,
        expected_version: fulfillment.version,
        op: op
      },
      extras
    )
  end

  defp valid_ref?(value), do: is_binary(value) and byte_size(value) in 1..128
end
