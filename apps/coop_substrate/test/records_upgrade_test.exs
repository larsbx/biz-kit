defmodule CoopSubstrate.RecordsUpgradeTest do
  use ExUnit.Case, async: false
  use CoopSubstrate.LogCase

  import CoopSubstrate.TaskTimingFixtures
  alias CoopSubstrate.{ArtifactCustody.Quota, Records, Log}

  test "application boot upgrades a ledger-only database without altering its bytes" do
    # A real signed ledger event must survive the production upgrade intact.
    gov = new_member("governance")
    assert {:ok, [_]} = Log.append(declare_governance(gov))
    head = Log.head()
    {:ok, conn} = raw_conn()
    before = Postgrex.query!(conn, "SELECT * FROM public.events ORDER BY event_id", []).rows
    :ok = Application.stop(:coop_substrate)

    on_exit(fn ->
      truncate_store!()
      Application.ensure_all_started(:coop_substrate)
    end)

    Postgrex.query!(conn, ~s(DROP SCHEMA "records" CASCADE), [])

    # The application itself must initialize Records before starting Quota.
    assert {:ok, _} = Application.ensure_all_started(:coop_substrate)

    assert Postgrex.query!(conn, "SELECT * FROM public.events ORDER BY event_id", []).rows ==
             before

    assert Log.head() == head
    assert :ok = Log.verify_chains()
    assert {:ok, reservation} = Quota.charge("upgrade-#{System.unique_integer()}", "a", 1, 1)
    assert :ok = Quota.commit(reservation)
    assert :ok = Records.setup!()
    GenServer.stop(conn)
  end

  test "concurrent node initializers serialize on a ledger-only database" do
    :ok = Application.stop(:coop_substrate)
    on_exit(fn -> Application.ensure_all_started(:coop_substrate) end)
    {:ok, conn} = raw_conn()
    Postgrex.query!(conn, ~s(DROP SCHEMA "records" CASCADE), [])
    parent = self()

    tasks =
      for _ <- 1..8 do
        Task.async(fn ->
          send(parent, {:ready, self()})
          receive do: (:start -> Records.setup!())
        end)
      end

    for task <- tasks do
      pid = task.pid
      assert_receive {:ready, ^pid}, 1_000
    end

    Enum.each(tasks, &send(&1.pid, :start))
    assert Enum.map(tasks, &Task.await(&1, 60_000)) == List.duplicate(:ok, 8)
    GenServer.stop(conn)
    assert {:ok, _} = Application.ensure_all_started(:coop_substrate)
  end
end
