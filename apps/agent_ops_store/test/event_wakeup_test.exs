defmodule AgentOpsStore.EventWakeupTest do
  use ExUnit.Case, async: false

  alias AgentOpsStore.EventWakeup

  defmodule StagingHost do
    def environment, do: :staging
  end

  defmodule ProductionHost do
    def environment, do: :production
  end

  @scope AgentOpsStore.EventWakeupTest.Group

  setup do
    start_supervised!(%{id: @scope, start: {:pg, :start_link, [@scope]}})
    :ok
  end

  test "cluster ledger hints are coalesced into a single generic worker wake" do
    {:ok, notifier} =
      EventWakeup.start_link(
        host: StagingHost,
        target: self(),
        scope: @scope,
        cooldown_ms: 25
      )

    assert notifier in :pg.get_members(@scope, :ledger)

    # Not even the shape of the event is authority. This is ONLY a wakeup.
    for _ <- 1..30, do: send(notifier, {:coop_ledger, [%{type: "untrusted"}]})

    assert_receive {:"$gen_cast", :wake}, 1000
    refute_receive {:"$gen_cast", :wake}, 70

    send(notifier, {:coop_ledger, [%{type: "TaskAgentRunRequestedV1"}]})
    assert_receive {:"$gen_cast", :wake}, 1000

    GenServer.stop(notifier)
  end

  test "no staging subscriber can be started with a production host" do
    assert {:error, :staging_only} =
             EventWakeup.start_link(host: ProductionHost, target: self(), scope: @scope)

    assert :pg.get_members(@scope, :ledger) == []
  end

  test "the notifier exits when the monitored worker stops" do
    target = spawn(fn -> receive do :stop -> :ok end end)

    {:ok, notifier} =
      EventWakeup.start_link(
        host: StagingHost,
        target: target,
        scope: @scope,
        cooldown_ms: 20
      )

    ref = Process.monitor(notifier)
    send(target, :stop)
    assert_receive {:DOWN, ^ref, :process, ^notifier, :normal}, 1000
  end

  test "an unavailable group or a dead worker is not silently authorized" do
    target = spawn(fn -> :ok end)
    ref = Process.monitor(target)
    assert_receive {:DOWN, ^ref, :process, ^target, :normal}, 1000

    assert {:error, :invalid_wakeup_target} =
             EventWakeup.start_link(host: StagingHost, target: target, scope: @scope)

    assert {:error, :invalid_wakeup_cooldown} =
             EventWakeup.start_link(
               host: StagingHost,
               target: self(),
               scope: @scope,
               cooldown_ms: 0
             )
  end
end
