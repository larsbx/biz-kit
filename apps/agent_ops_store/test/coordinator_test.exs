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
    assert {:error, :staging_only} = Coordinator.recover(nil, :key, ProductionHost, "worker")
    assert {:error, :staging_only} = Coordinator.tick(nil, ProductionHost, "worker")
    assert {:error, :staging_only} = AgentOpsStore.Worker.start_link(host: ProductionHost)
  end

  test "unknown, mutating and malformed tools are denied without reaching a database" do
    for tool <- ["task.write", "task.complete", "shell", "apply", "candidate.submit"] do
      assert {:error, :unknown_or_malformed_execution_tool} =
               AgentOpsStore.ToolProxy.call(nil, ProductionHost, %{}, %{
                 name: tool,
                 arguments: %{}
               })
    end

    assert {:error, :staging_only} =
             AgentOpsStore.ToolProxy.call(nil, ProductionHost, %{}, %{
               name: "task.read",
               arguments: %{}
             })

    assert {:error, :invalid_tool_arguments} =
             AgentOpsStore.ToolProxy.call(nil, ProductionHost, %{}, %{
               name: "task.read",
               arguments: %{principal_id: "forged"}
             })
  end
end
