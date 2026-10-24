defmodule AgentCore.RecoveryPort do
  @moduledoc """
  Optional backend effect lookup extension, required by the staging coordinator.

  Lookup uses the same immutable effect ID as launch, even when a crash lost
  the returned backend handle. It must cover in-flight creates and permanent
  idempotency records. A transient 404, empty list, timeout or cancel request
  is not proof of absence/termination. Observations remain untrusted until the
  host verifies their provenance, effect, backend identity and output timing.
  No lease token, business grant or task body is passed to lookup.
  """

  @callback lookup(profile :: map(), effect_id :: String.t()) ::
              {:ok, map()} | {:error, term()}

  @features ~w(idempotent_launch_v1 effect_lookup_v1 cancellation_v1 bounded_results_v1)

  def check(adapter, %{manifest: %{"parameters" => %{"capabilities" => caps}}})
      when is_atom(adapter) and is_map(caps) do
    if Code.ensure_loaded?(adapter) and
         Enum.all?([launch: 3, poll: 1, cancel: 2, lookup: 2], fn {name, arity} ->
           function_exported?(adapter, name, arity)
         end) and is_list(caps["features"]) and
         Enum.all?(@features, &(&1 in caps["features"])),
       do: :ok,
       else: {:error, :backend_recovery_contract_required}
  end

  def check(_adapter, _profile), do: {:error, :backend_recovery_contract_required}
end
