defmodule AgentOpsStore.CoordinatorTest do
  use ExUnit.Case, async: true

  alias AgentOpsStore.Coordinator

  defmodule ProductionHost do
    def environment, do: :production
  end

  test "production cannot enqueue, dispatch, scan or cancel through the staging bridge" do
    assert {:error, :staging_only} = Coordinator.enqueue(nil, :key, ProductionHost)
    assert {:error, :staging_only} = Coordinator.deliver(nil, :key, ProductionHost, "worker")
    assert {:error, :staging_only} = Coordinator.enqueue_all(nil, ProductionHost)
    assert {:error, :staging_only} = Coordinator.withdraw(nil, :key, ProductionHost)
  end
end
