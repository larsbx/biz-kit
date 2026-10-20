defmodule SpruceGoose.LifecycleTest do
  @moduledoc """
  One contract (`TaskCore.Lifecycle`), two machines.

  Every property here is decided, not sampled: the relations are finite, so
  the tests enumerate the whole state set and the whole relation.
  """
  use ExUnit.Case, async: true

  alias SpruceGoose.Deployment
  alias SpruceGoose.Workflows
  alias SpruceGoose.Workflows.TaskState

  @machines [Workflows.Lifecycle, Deployment.Lifecycle]

  # The contract's own properties are TaskCore's tests; these are its
  # declarations here.
  for machine <- @machines do
    describe inspect(machine) do
      @machine machine

      test "is a versioned TaskCore.Lifecycle, every state reachable and able to finish" do
        assert TaskCore.Lifecycle in behaviours(@machine)
        assert is_integer(@machine.version()) and @machine.version() >= 1
        assert TaskCore.Lifecycle.violations(@machine) == []
      end
    end
  end

  describe "task lifecycle" do
    test "is exactly the relation the Task resource enforces" do
      assert Workflows.Lifecycle.version() == 1
      assert Workflows.Lifecycle.initial() == :inbox

      assert Workflows.Lifecycle.transitions() == %{
               inbox: [:proposed, :cancelled],
               proposed: [:queued, :cancelled],
               queued: [:ready, :blocked, :cancelled],
               ready: [:in_progress, :blocked, :cancelled],
               in_progress: [:waiting, :blocked, :completed, :failed, :cancelled],
               waiting: [:ready, :in_progress, :blocked, :cancelled],
               blocked: [:ready, :cancelled],
               failed: [:queued, :cancelled],
               completed: [],
               cancelled: []
             }

      assert Enum.sort(Workflows.Lifecycle.terminal_states()) == [:cancelled, :completed]
    end

    test "the persisted enum is the lifecycle's state set, in declaration order" do
      assert TaskState.values() == Workflows.Lifecycle.states()

      assert Workflows.Lifecycle.states() ==
               ~w(inbox proposed queued ready in_progress waiting blocked completed failed cancelled)a
    end

    test "failed is recoverable, completed and cancelled are absorbing" do
      refute Workflows.Lifecycle.terminal?(:failed)
      assert {:ok, :queued} = Workflows.Lifecycle.transition(:failed, :queued)

      for terminal <- Workflows.Lifecycle.terminal_states(), to <- Workflows.Lifecycle.states() do
        assert {:error, :invalid_transition} = Workflows.Lifecycle.transition(terminal, to)
      end
    end
  end

  describe "deployment lifecycle" do
    test "carries the native control plane's relation unchanged" do
      assert Deployment.Lifecycle.version() == 1
      assert Deployment.Lifecycle.initial() == :queued

      assert Deployment.Lifecycle.transitions() == %{
               queued: [:building, :cancelled],
               building: [:staged, :failed, :cancelled],
               staged: [:deploying, :cancelled],
               deploying: [:verifying, :failed, :rolling_back],
               verifying: [:ready, :failed, :rolling_back],
               ready: [:rolling_back],
               failed: [:rolling_back],
               rolling_back: [:rolled_back, :failed],
               rolled_back: [],
               cancelled: []
             }

      assert Enum.sort(Deployment.Lifecycle.terminal_states()) ==
               [:cancelled, :failed, :ready, :rolled_back]
    end

    test "terminal is finished, not absorbing: ready and failed may still roll back" do
      assert Deployment.Lifecycle.terminal?(:ready)
      assert {:ok, :rolling_back} = Deployment.Lifecycle.transition(:ready, :rolling_back)
    end
  end

  defp behaviours(module),
    do: module.module_info(:attributes) |> Keyword.get_values(:behaviour) |> List.flatten()
end
