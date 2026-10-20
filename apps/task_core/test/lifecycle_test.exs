defmodule TaskCore.LifecycleTest do
  @moduledoc """
  The contract, and the task lifecycle declared on it.

  Every property here is decided, not sampled: the relations are finite, so
  the tests enumerate the whole state set and the whole relation.
  """
  use ExUnit.Case, async: true

  alias TaskCore.{Lifecycle, TaskLifecycle}

  defmodule Rollout do
    @moduledoc false
    # Terminal is wider than absorbing: a finished rollout may still roll back.
    use TaskCore.Lifecycle,
      version: 2,
      initial: :staged,
      transitions: [
        staged: [:live, :cancelled],
        live: [:rolled_back],
        rolled_back: [],
        cancelled: []
      ],
      terminal: [:live, :rolled_back, :cancelled]
  end

  for machine <- [TaskLifecycle, Rollout] do
    describe inspect(machine) do
      @machine machine

      test "is a versioned TaskCore.Lifecycle" do
        assert Lifecycle in behaviours(@machine)
        assert is_integer(@machine.version()) and @machine.version() >= 1
      end

      test "the relation is closed over the declared state set" do
        states = MapSet.new(@machine.states())

        assert @machine.initial() in states
        assert MapSet.subset?(MapSet.new(@machine.terminal_states()), states)

        for {from, successors} <- @machine.transitions() do
          assert from in states
          assert MapSet.subset?(MapSet.new(successors), states), "#{from} leaves the state set"
        end

        assert Enum.sort(Map.keys(@machine.transitions())) == Enum.sort(@machine.states())
      end

      test "every sink state is terminal" do
        for state <- @machine.states(), @machine.successors(state) == [] do
          assert @machine.terminal?(state), "#{state} has no successors but is not terminal"
        end
      end

      test "every state is reachable, and can reach a terminal state" do
        assert Lifecycle.violations(@machine) == []
        assert Enum.sort(@machine.reachable()) == Enum.sort(@machine.states())
      end

      test "transition/2, allowed?/2 and allowed_from/1 are the same relation" do
        for from <- @machine.states(), to <- @machine.states() do
          expected =
            if to in @machine.successors(from),
              do: {:ok, to},
              else: {:error, :invalid_transition}

          assert @machine.transition(from, to) == expected
          assert @machine.allowed?(from, to) == match?({:ok, _}, expected)
        end

        for state <- @machine.states() do
          assert @machine.allowed_from(state) == @machine.successors(state)
        end
      end

      test "unknown states have no successors" do
        assert @machine.successors(:sudo) == []
        assert @machine.transition(:sudo, @machine.initial()) == {:error, :invalid_transition}
        assert @machine.transition(@machine.initial(), :sudo) == {:error, :invalid_transition}
        refute @machine.allowed?(:sudo, :sudo)
      end

      test "parse/1 round-trips persisted names and refuses everything else" do
        for state <- @machine.states() do
          assert {:ok, ^state} = @machine.parse(Atom.to_string(state))
          assert {:ok, ^state} = @machine.parse(state)
        end

        assert {:error, :unknown_state} = @machine.parse("sudo")
        assert {:error, :unknown_state} = @machine.parse(:sudo)
        assert {:error, :unknown_state} = @machine.parse(nil)
      end
    end
  end

  describe "task lifecycle" do
    test "is exactly the relation the ledger admits" do
      assert TaskLifecycle.version() == 1
      assert TaskLifecycle.initial() == :inbox

      assert TaskLifecycle.states() ==
               ~w(inbox proposed queued ready in_progress completed cancelled)a

      assert TaskLifecycle.transitions() == %{
               inbox: [:proposed, :cancelled],
               proposed: [:queued, :cancelled],
               queued: [:ready, :cancelled],
               ready: [:in_progress, :cancelled],
               in_progress: [:completed, :queued, :cancelled],
               completed: [],
               cancelled: []
             }

      assert Enum.sort(TaskLifecycle.terminal_states()) == [:cancelled, :completed]
    end

    test "completed and cancelled are absorbing; reopening goes back to queued" do
      assert {:ok, :queued} = TaskLifecycle.transition(:in_progress, :queued)

      for terminal <- TaskLifecycle.terminal_states(), to <- TaskLifecycle.states() do
        assert {:error, :invalid_transition} = TaskLifecycle.transition(terminal, to)
      end
    end
  end

  describe "declaration verification" do
    test "refuses a successor outside the state set" do
      assert_raise ArgumentError, ~r/undeclared state.*:gone/, fn ->
        Lifecycle.verify!(Bad, :a, [a: [:gone]], [])
      end
    end

    test "refuses an initial state outside the state set" do
      assert_raise ArgumentError, ~r/initial state :z/, fn ->
        Lifecycle.verify!(Bad, :z, [a: []], [:a])
      end
    end

    test "refuses a terminal state outside the state set" do
      assert_raise ArgumentError, ~r/terminal state :z/, fn ->
        Lifecycle.verify!(Bad, :a, [a: []], [:a, :z])
      end
    end

    test "refuses a sink state that is not terminal" do
      assert_raise ArgumentError, ~r/sink state :b/, fn ->
        Lifecycle.verify!(Bad, :a, [a: [:b], b: []], [:a])
      end
    end

    test "refuses a duplicated state" do
      assert_raise ArgumentError, ~r/declared twice/, fn ->
        Lifecycle.verify!(Bad, :a, [a: [], a: []], [:a])
      end
    end

    test "accepts a well-formed declaration" do
      assert :ok = Lifecycle.verify!(Good, :a, [a: [:b], b: []], [:b])
    end
  end

  describe "violations/1" do
    defmodule Stranded do
      @moduledoc false
      # :orphan is unreachable; :loop can never finish.
      use TaskCore.Lifecycle,
        version: 1,
        initial: :a,
        transitions: [a: [:done, :loop], loop: [:loop], orphan: [:done], done: []]
    end

    test "names each unreachable state and each state that cannot terminate" do
      assert Lifecycle.violations(Stranded) == [cannot_terminate: :loop, unreachable: :orphan]
    end
  end

  defp behaviours(module),
    do: module.module_info(:attributes) |> Keyword.get_values(:behaviour) |> List.flatten()
end
