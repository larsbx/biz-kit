defmodule FederationService.SubscriptionAuthority do
  @moduledoc """
  Trusted host port wrapping a subscription admission or delivery effect.

  `subscription_authority` receives the exact request and a synchronous
  zero-argument effect, and returns `{:ok, effect_result}` only after executing
  it under current authority. CoopSubstrate.FederationAuthority.port/1 supplies
  the native signed-ledger and revocation fence without a service dependency
  on the ledger. Ports must call the effect at most once and never retain it.

  The older approval_verifier is a pilot-only compatibility boundary. It is
  rechecked for delivery, but does not provide an atomic revocation fence.
  """
  def run(config, follow_id, operation, receipt, activity_id, effect) do
    request = %{
      local_actor: config.actor,
      follow_id: follow_id,
      operation: operation,
      receipt: receipt,
      activity_id: activity_id
    }

    case Map.get(config, :subscription_authority) do
      port when is_function(port, 2) -> port.(request, effect)
      nil -> legacy(config, request, effect)
      _ -> {:error, :unverified_local_authority}
    end
  rescue
    _ -> {:error, :unverified_local_authority}
  catch
    _, _ -> {:error, :unverified_local_authority}
  end

  defp legacy(config, request, effect) do
    with verifier when is_function(verifier, 5) <- config.approval_verifier,
         :ok <-
           verifier.(
             request.local_actor,
             request.follow_id,
             request.operation,
             request.receipt,
             System.system_time(:second)
           ) do
      {:ok, effect.()}
    else
      _ -> {:error, :unverified_local_authority}
    end
  end
end
