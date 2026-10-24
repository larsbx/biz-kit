defmodule TaskCore.Dispatcher do
  @moduledoc """
  Generic host-side delivery algorithm for a durable operational outbox.

  All ports are trusted server functions, never caller-supplied tools. prepare
  must authorize against fresh committed business replay. register and claim
  must commit before launch; claim is transactional CAS in the durable host
  store. The store is a projection, never business authority. This algorithm
  works for any executor and contains no agent, profile or runtime policy.

  Ambiguous launch or attachment failure retains the lease. Redelivery NEVER
  relaunches a leased effect, even after expiry. A separate trusted reconciler
  must prove its external outcome before making it pending again. Returned
  lease material is host-only and must never reach an executor or public API.
  """

  def enqueue(key, ports) do
    with {:ok, plan} <- ports.prepare.(key),
         {:ok, disposition} <- ports.register.(plan) do
      {:ok, %{effect_id: plan.effect_id, disposition: disposition}}
    end
  end

  def deliver(key, ports) do
    with {:ok, plan} <- ports.prepare.(key),
         {:ok, _} <- ports.register.(plan),
         {:ok, row} <- ports.snapshot.(plan.effect_id) do
      if row.phase == "pending" do
        claim_and_launch(key, plan, row, ports)
      else
        {:ok, %{effect_id: plan.effect_id, disposition: :already_dispatched, phase: row.phase}}
      end
    end
  end

  defp claim_and_launch(key, plan, row, ports) do
    with {:ok, lease} <- ports.claim.(plan.effect_id, row.version) do
      # Check again after the durable claim. No cached authorization from
      # enqueue, a previous delivery or before a database wait is reused.
      case ports.prepare.(key) do
        {:ok, ^plan} -> launch(plan, lease, ports)
        _ -> fence(plan, lease, ports)
      end
    end
  end

  defp fence(plan, lease, ports) do
    case ports.request_cancel.(plan.effect_id, lease.version) do
      {:ok, _} -> {:error, :authority_changed_after_claim}
      _ -> {:error, :cancellation_requires_reconciliation}
    end
  end

  defp launch(plan, lease, ports) do
    # A backend error, exception or lost response cannot establish absence.
    # In all such cases the durable leased row blocks another launch.
    case ports.launch.(plan) do
      {:ok, reference} when is_binary(reference) ->
        case ports.attach.(plan.effect_id, lease, reference) do
          {:ok, version} ->
            {:ok,
             %{
               effect_id: plan.effect_id,
               disposition: :dispatched,
               lease: %{lease | version: version},
               backend_ref: reference
             }}

          _ ->
            {:error, :launch_requires_reconciliation}
        end

      _ ->
        {:error, :launch_requires_reconciliation}
    end
  rescue
    _ -> {:error, :launch_requires_reconciliation}
  catch
    :exit, _ -> {:error, :launch_requires_reconciliation}
  end
end
