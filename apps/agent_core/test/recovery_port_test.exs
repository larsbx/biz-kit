defmodule AgentCore.RecoveryPortTest do
  use ExUnit.Case, async: true
  alias AgentCore.RecoveryPort

  defmodule Recoverable do
    def launch(_, _, _), do: {:error, :fixture_only}
    def poll(_), do: {:error, :fixture_only}
    def cancel(_, _), do: {:error, :fixture_only}
    def lookup(_, _), do: {:error, :fixture_only}
  end

  defmodule NoLookup do
    def launch(_, _, _), do: {:error, :fixture_only}
    def poll(_), do: {:error, :fixture_only}
    def cancel(_, _), do: {:error, :fixture_only}
  end

  @features ~w(idempotent_launch_v1 effect_lookup_v1 cancellation_v1 bounded_results_v1)
  defp profile(features),
    do: %{manifest: %{"parameters" => %{"capabilities" => %{"features" => features}}}}

  test "staging requires both versioned feature declarations and actual callback support" do
    assert :ok = RecoveryPort.check(Recoverable, profile(@features))

    assert {:error, :backend_recovery_contract_required} =
             RecoveryPort.check(NoLookup, profile(@features))

    for feature <- @features do
      assert {:error, :backend_recovery_contract_required} =
               RecoveryPort.check(Recoverable, profile(@features -- [feature]))
    end
  end

  test "unversioned or malformed capability claims fail closed" do
    for features <- [nil, "effect_lookup_v1", [], ~w(idempotency lookup cancellation results)] do
      assert {:error, :backend_recovery_contract_required} =
               RecoveryPort.check(Recoverable, profile(features))
    end

    assert {:error, :backend_recovery_contract_required} = RecoveryPort.check(Recoverable, %{})
  end
end
