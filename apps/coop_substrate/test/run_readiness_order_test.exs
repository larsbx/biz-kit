defmodule CoopSubstrate.RunReadinessOrderTest do
  @moduledoc """
  A run's batch lists its tasks in task ID order, as the device that signs it
  expects, however many tasks the ledger holds: a map is unordered past 32
  entries.
  """
  use ExUnit.Case, async: true

  alias CoopSubstrate.RunReadiness

  test "pending tasks come in task ID order past 32 tasks" do
    ids = for n <- 0..39, do: "t" <> String.pad_leading("#{n}", 2, "0")

    tasks =
      Map.new(ids, fn id ->
        {{"ch", "tn", "pr", id}, %{state: "proposed", blueprint: %{run_event_id: "run"}}}
      end)

    assert Enum.map(
             RunReadiness.pending(%{tasks: tasks}, {"ch", "tn", "pr"}, "run"),
             &elem(&1, 0)
           ) ==
             ids
  end
end
