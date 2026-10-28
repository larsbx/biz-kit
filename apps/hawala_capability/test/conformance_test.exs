defmodule HawalaCapability.ConformanceTest do
  use ExUnit.Case, async: false
  alias HawalaCapability.{TestHost, TestJournal}

  defp directory do
    root =
      Path.join(
        System.tmp_dir!(),
        "hawala-host-test-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    root
  end

  defp fresh do
    root = Path.join(directory(), "cluster")
    {:ok, host} = TestHost.create(root)
    on_exit(fn -> TestHost.close(host) end)
    host
  end

  defp event(host, id, action) do
    {:ok, host, _} = TestHost.apply(host, id, action)
    host
  end

  defp ready(host) do
    Enum.with_index(~w|sendPrepare prepareL(0,0,0) prepareR(0,0,0) receiveL receiveR|)
    |> Enum.reduce(host, fn {action, i}, h -> event(h, "ready-#{i}", action) end)
  end

  defp number("true"), do: 1
  defp number("false"), do: 0
  defp number(value), do: String.to_integer(value)

  test "all 232 formal prefixes replay through independent synced actor journals" do
    [header | rows] =
      File.read!(Path.join(__DIR__, "fixtures/crossAuthority.tsv"))
      |> String.split("\n", trim: true)

    assert Enum.drop(String.split(header, "\t"), 3) == TestHost.fields()
    assert length(rows) == 232
    parsed = Enum.map(rows, &String.split(&1, "\t"))
    assert Enum.map(parsed, &hd/1) |> Enum.uniq() |> length() == 13
    assert Enum.map(parsed, &(Enum.at(&1, 1) |> String.to_integer())) == Enum.to_list(0..231)

    Enum.chunk_by(parsed, &hd/1)
    |> Enum.each(fn scenario ->
      host = fresh()

      final =
        Enum.reduce(scenario, host, fn [name, prefix, action | values], h ->
          expected = Enum.zip(TestHost.fields(), Enum.map(values, &number/1)) |> Map.new()
          id = "prefix-#{prefix}"
          {:ok, h, receipt} = TestHost.apply(h, id, action)
          assert TestHost.projection(h) == expected, "#{name} prefix #{prefix}: #{action}"
          assert TestHost.safe?(expected)

          if receipt do
            {:ok, replayed_host, replayed} = TestHost.apply(h, id, action)
            assert replayed.replayed
            assert Map.drop(replayed, [:replayed]) == Map.drop(receipt, [:replayed])
            assert TestHost.projection(replayed_host) == expected
          end

          {:ok, reopened} = TestHost.reopen(h)
          assert TestHost.projection(reopened) == expected
          reopened
        end)

      TestHost.close(final)
    end)
  end

  test "all 72 Lean workflow gates match; unverified and uncertain evidence cannot advance" do
    [_ | rows] =
      File.read!(Path.join(__DIR__, "fixtures/financialGates.tsv"))
      |> String.split("\n", trim: true)

    assert length(rows) == 72

    Enum.each(rows, fn row ->
      [verified, state, action, allowed] = String.split(row, "\t")
      assert TestHost.workflow_gate(verified == "true", state, action) == {:ok, allowed == "true"}
    end)

    assert {:error, _} = TestHost.workflow_gate(true, "Settled", "checkoutFulfill")
    assert {:error, _} = TestHost.workflow_gate(true, "settled", "shipAnyway")
    assert {:error, _} = TestHost.workflow_gate("true", "settled", "checkoutFulfill")
  end

  test "permanent replay and payload conflicts survive actor restart without rolling back state" do
    host = fresh()
    {:ok, host, held} = TestHost.apply(host, "early", "commit")
    host = ready(host) |> event("terminal", "commit")
    before = TestHost.projection(host)
    {:ok, host, prior} = TestHost.apply(host, "early", "commit")
    assert prior.replayed and prior.local == held.local
    assert TestHost.projection(host) == before
    assert {:error, :payload_conflict} = TestHost.apply(host, "early", "abort")
    {:ok, restored} = TestHost.reopen(host)
    assert {:error, :payload_conflict} = TestHost.apply(restored, "terminal", "abort")
    assert TestHost.projection(event(restored, "late-abort", "abort"))["decision"] == 1
    TestHost.close(restored)
  end

  test "one worker committing does not advance either independent participant" do
    host = fresh() |> ready() |> event("decision", "commit")
    assert TestHost.held?(host, :left) and TestHost.held?(host, :right)
    host = host |> event("publish", "publish") |> event("left", "deliverL")
    assert TestHost.projection(host)["localL"] == 1
    assert TestHost.projection(host)["localR"] == 0
  end

  test "competing calls to the coordinator cannot install opposing terminal decisions" do
    host = fresh() |> ready()

    tasks =
      for action <- ~w(commit abort),
          do: Task.async(fn -> TestHost.apply(host, action, action) end)

    results = Enum.map(tasks, &Task.await/1)
    assert Enum.any?(results, &match?({:ok, _, _}, &1))
    assert TestHost.projection(host)["decision"] in [1, 2]
    assert TestHost.projection(host)["localL"] == 0
    assert TestHost.projection(host)["localR"] == 0
  end

  test "missing, mismatched, or corrupt history fails closed instead of enrolling a replacement" do
    host = fresh()
    root = host.root
    TestHost.close(host)
    File.rm!(Path.join(root, "left.log"))
    assert {:error, _} = TestHost.open_existing(root)
    File.cp!(Path.join(root, "coordinator.log"), Path.join(root, "left.log"))
    assert {:error, _} = TestHost.open_existing(root)
    File.write!(Path.join(root, "left.log"), "not a journal")
    assert {:error, _} = TestHost.open_existing(root)
  end

  test "invalid events never enter journals and malformed local state is rejected" do
    host = fresh()
    before = TestHost.projection(host)

    for action <- [
          "prepareL",
          "prepareL(0,0)",
          "prepareL(00,0,0)",
          "prepareL(-1,0,0)",
          "prepareL(0,0,0)junk",
          "settle",
          "timeout(0)"
        ] do
      assert {:error, _} = TestHost.apply(host, "bad", action)
    end

    assert {:error, :invalid_id} = TestHost.apply(host, "é", "sendPrepare")
    assert TestHost.projection(host) == before
    {version, local} = TestJournal.snapshot(host.pids.left)

    assert {:error, :invalid_state} =
             TestJournal.apply(
               host.pids.left,
               "invalid-state",
               "test",
               version,
               Map.put(local, "voteL", 9)
             )
  end

  test "each journal has one owner in the test VM and stale writers cannot overwrite it" do
    host = fresh()
    {version, local} = TestJournal.snapshot(host.pids.left)

    assert {:error, {:already_started, _}} =
             TestJournal.start(Path.join(host.root, "left.log"), :left, local, false)

    assert {:error, :stale_version} =
             TestJournal.apply(host.pids.left, "stale", "test", version + 1, local)
  end

  test "the conformance comparison rejects a deliberately false commit projection" do
    host = fresh() |> event("first", "sendPrepare")
    actual = TestHost.projection(host)
    mutated = Map.put(actual, "decision", 1)
    refute actual == mutated
    refute TestHost.safe?(mutated)
  end

  @tag capture_log: true
  test "a failed durable append returns HOLD without changing the stored decision" do
    host = fresh() |> ready()
    before = TestHost.projection(host)
    log = :sys.get_state(host.pids.coordinator).log
    size = File.stat!(Path.join(host.root, "coordinator.log")).size
    assert :ok = :disk_log.change_size(log, size)
    assert {:error, {:hold, _}} = TestHost.apply(host, "uncertain", "commit")
    TestHost.close(host)
    {:ok, restored} = TestHost.open_existing(host.root)
    assert TestHost.projection(restored) == before
    TestHost.close(restored)
  end

  @tag capture_log: true
  test "a killed worker never causes automatic replacement enrollment or an assumed peer commit" do
    host = fresh() |> ready() |> event("decision", "commit")
    ref = Process.monitor(host.pids.coordinator)
    Process.exit(host.pids.coordinator, :kill)
    assert_receive {:DOWN, ^ref, :process, _, :killed}
    assert {:error, {:hold, :unavailable_actor}} = TestHost.apply(host, "late", "abort")
    TestHost.close(host)

    case TestHost.open_existing(host.root) do
      {:ok, restored} ->
        assert TestHost.projection(restored)["decision"] == 1
        assert TestHost.held?(restored, :left) and TestHost.held?(restored, :right)
        assert {:error, :payload_conflict} = TestHost.apply(restored, "decision", "abort")
        TestHost.close(restored)

      {:error, _} ->
        # An unclean log is intentionally not auto-repaired. The original
        # nonempty journal stays available for separately authorized recovery.
        assert File.stat!(Path.join(host.root, "coordinator.log")).size > 0
    end
  end
end
