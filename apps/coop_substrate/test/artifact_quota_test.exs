defmodule CoopSubstrate.ArtifactQuotaTest do
  @moduledoc """
  The evidence quota (`ArtifactCustody.Quota`): reservations while a write is
  in flight, a charge per distinct digest once it succeeds, kept across a
  restart of the quota process (docs/architecture/2026-10-20-durable-quota.md).
  """
  use ExUnit.Case, async: false
  alias CoopSubstrate.ArtifactCustody.Quota

  # A key as the quota is given one: plain data, recorded and read back in
  # any VM (a ref names its node, which no later VM knows).
  setup do: %{key: "quota-test-#{System.os_time()}-#{System.unique_integer([:positive])}"}

  test "only successful distinct digests consume room, including retries at the limit", %{
    key: key
  } do
    for _ <- 1..5 do
      assert Quota.store(key, "a", 8, 32, fn -> {:error, :enospc} end) == {:error, :enospc}
    end

    for digest <- ~w(a b c d) do
      assert Quota.store(key, digest, 8, 32, fn -> {:ok, digest} end) == {:ok, digest}
    end

    assert Quota.store(key, "a", 8, 32, fn -> {:ok, "a"} end) == {:ok, "a"}
    # A failed restoration must not erase an earlier successful charge.
    assert Quota.store(key, "a", 8, 32, fn -> {:error, :enospc} end) == {:error, :enospc}

    assert Quota.store(key, "e", 1, 32, fn -> flunk("over-quota write ran") end) ==
             {:error, :quota_exceeded}
  end

  test "a concurrent success survives the first writer's later failure", %{key: key} do
    parent = self()

    first =
      Task.async(fn ->
        Quota.store(key, "a", 8, 8, fn ->
          send(parent, {:writing, self()})
          receive do: (:fail -> {:error, :enospc})
        end)
      end)

    assert_receive {:writing, pid}
    assert Quota.store(key, "a", 8, 8, fn -> {:ok, "a"} end) == {:ok, "a"}
    send(pid, :fail)
    assert Task.await(first) == {:error, :enospc}
    assert Quota.charge(key, "b", 1, 8) == {:error, :quota_exceeded}
  end

  test "a failed writer cannot release another pending writer's room", %{key: key} do
    {:ok, first} = Quota.charge(key, "a", 8, 8)
    {:ok, second} = Quota.charge(key, "a", 8, 8)
    refute first == second
    assert Quota.refund(first) == :ok
    assert Quota.charge(key, "b", 1, 8) == {:error, :quota_exceeded}
    assert Quota.refund(second) == :ok
    {:ok, replacement} = Quota.charge(key, "a", 8, 8)
    # A stale refund cannot remove a new reservation for the same digest.
    assert Quota.refund(first) == :ok
    assert Quota.charge(key, "b", 1, 8) == {:error, :quota_exceeded}
    assert Quota.commit(replacement) == :ok
    assert Quota.refund(replacement) == :ok
    assert Quota.charge(key, "b", 1, 8) == {:error, :quota_exceeded}
  end

  test "exceptions release reservations and leave the quota process usable", %{key: key} do
    assert_raise RuntimeError, "failed write", fn ->
      Quota.store(key, "a", 8, 8, fn -> raise "failed write" end)
    end

    assert Quota.store(key, "b", 8, 8, fn -> {:ok, "b"} end) == {:ok, "b"}
  end

  test "worker death refunds absent bytes but preserves a write that landed before commit", %{
    key: key
  } do
    alias CoopSubstrate.Harness.Artifacts
    server = BizKit.Cluster.Singleton.whereis_name(Quota)
    parent = self()
    :erlang.trace(server, true, [:receive])
    on_exit(fn -> if Process.alive?(server), do: :erlang.trace(server, false, [:receive]) end)

    for landed <- [false, true] do
      bytes = "worker-death-#{System.unique_integer([:positive])}"
      digest = :crypto.hash(:sha256, bytes)
      size = byte_size(bytes)
      scope = {key, landed}
      root = Application.get_env(:coop_substrate, :artifact_dir, "priv/artifacts")
      path = Path.join(root, Base.encode16(digest, case: :lower))
      File.rm(path)
      on_exit(fn -> File.rm(path) end)

      writer =
        spawn(fn ->
          {:ok, _reservation} = Quota.charge(scope, digest, size, size)
          if landed, do: {:ok, ^digest} = Artifacts.put(bytes)
          send(parent, {:reserved, self()})
          receive do: (:stop -> :ok)
        end)

      assert_receive {:reserved, ^writer}, 1_000
      Process.exit(writer, :kill)
      # Observe delivery of the real monitor signal, then query the server
      # behind that handler. No sleeps or scheduler-dependent race window.
      assert_receive {:trace, ^server, :receive, {:DOWN, _, :process, ^writer, :killed}},
                     1_000

      if landed do
        assert Quota.charge(scope, "extra", 1, size) == {:error, :quota_exceeded}
        assert {:ok, :held} = Quota.charge(scope, digest, size, size)
        assert {:ok, ^bytes} = Artifacts.get(digest)
      else
        assert {:ok, replacement} = Quota.charge(scope, "extra", 1, size)
        assert Quota.refund(replacement) == :ok
      end
    end
  end

  test "the same digest is charged separately to each person, scope and task", %{key: key} do
    for scope <- [
          {key, "alice", "project", "task"},
          {key, "bob", "project", "task"},
          {key, "alice", "other project", "task"},
          {key, "alice", "project", "other task"}
        ] do
      assert Quota.store(scope, "a", 8, 8, fn -> {:ok, "a"} end) == {:ok, "a"}
      assert Quota.charge(scope, "b", 1, 8) == {:error, :quota_exceeded}
    end
  end

  describe "durable (docs/architecture/2026-10-20-durable-quota.md)" do
    # As when the quota process moves to another node, or the cluster restarts.
    defp restart_quota do
      sup = CoopSubstrate.Supervisor
      :ok = Supervisor.terminate_child(sup, Quota)
      {:ok, _} = Supervisor.restart_child(sup, Quota)
      :ok
    end

    test "committed evidence still counts after the quota process restarts", %{key: key} do
      for digest <- ~w(a b),
          do: {:ok, ^digest} = Quota.store(key, digest, 8, 16, fn -> {:ok, digest} end)

      restart_quota()

      assert Quota.charge(key, "c", 1, 16) == {:error, :quota_exceeded}
      # A stored file is held: storing it again costs nothing.
      assert Quota.charge(key, "a", 8, 16) == {:ok, :held}
      # Another person's, scope's or task's room is their own.
      assert {:ok, _} = Quota.charge(key <> "-other", "c", 16, 16)
    end

    test "a write in flight across a restart keeps its room, and is recorded when it succeeds",
         %{key: key} do
      {:ok, reservation} = Quota.charge(key, "a", 8, 8)
      restart_quota()

      # Still reserved: no second full upload while the first may yet land.
      assert Quota.charge(key, "b", 8, 8) == {:error, :quota_exceeded}

      assert Quota.commit(reservation) == :ok
      assert Quota.charge(key, "b", 1, 8) == {:error, :quota_exceeded}

      restart_quota()
      assert Quota.charge(key, "a", 8, 8) == {:ok, :held}
    end

    @tag :restart_race
    test "recovery cannot reassign room while a restored writer is still alive", %{key: key} do
      alias CoopSubstrate.Harness.Artifacts
      bytes = "slow-upload-#{key}"
      digest = :crypto.hash(:sha256, bytes)
      size = byte_size(bytes)
      parent = self()

      writer =
        Task.async(fn ->
          Quota.store(key, digest, size, size, fn ->
            send(parent, :write_paused)
            receive do: (:land -> Artifacts.put(bytes))
          end)
        end)

      assert_receive :write_paused, 1_000
      restart_quota()
      server = BizKit.Cluster.Singleton.whereis_name(Quota)
      # Deterministically execute the old grace timer while the writer is
      # paused before file creation, rather than racing a wall-clock sleep.
      send(server, :resolve_restored)
      _ = :sys.get_state(server)
      assert Quota.charge(key, "replacement", size, size) == {:error, :quota_exceeded}
      send(writer.pid, :land)
      assert Task.await(writer) == {:ok, digest}
      restart_quota()
      assert Quota.charge(key, digest, size, size) == {:ok, :held}
      assert Quota.charge(key, "replacement", 1, size) == {:error, :quota_exceeded}
    end

    test "a write in flight across a restart that then fails gives its room back", %{key: key} do
      {:ok, reservation} = Quota.charge(key, "a", 8, 8)
      restart_quota()
      assert Quota.refund(reservation) == :ok
      assert {:ok, _} = Quota.charge(key, "b", 8, 8)
    end

    test "a dead restored writer releases only proven-absent bytes", %{key: key} do
      alias CoopSubstrate.Harness.Artifacts
      parent = self()
      sup = CoopSubstrate.Supervisor

      for landed <- [false, true] do
        bytes = "dead-restored-#{key}-#{landed}"
        digest = :crypto.hash(:sha256, bytes)
        size = byte_size(bytes)
        scope = {key, landed}

        writer =
          spawn(fn ->
            {:ok, _} = Quota.charge(scope, digest, size, size)
            if landed, do: {:ok, ^digest} = Artifacts.put(bytes)
            send(parent, {:reserved, self()})
            receive do: (:stop -> :ok)
          end)

        assert_receive {:reserved, ^writer}, 1_000
        :ok = Supervisor.terminate_child(sup, Quota)
        ref = Process.monitor(writer)
        send(writer, :stop)
        assert_receive {:DOWN, ^ref, :process, ^writer, :normal}, 1_000
        {:ok, _} = Supervisor.restart_child(sup, Quota)
        recover_now()

        if landed do
          assert Quota.charge(scope, digest, size, size) == {:ok, :held}
          assert Quota.charge(scope, "other", 1, size) == {:error, :quota_exceeded}
        else
          assert {:ok, reservation} = Quota.charge(scope, "other", size, size)
          :ok = Quota.refund(reservation)
        end
      end
    end

    test "a restored live writer is monitored again for death", %{key: key} do
      parent = self()
      digest = :crypto.hash(:sha256, "absent-#{key}")

      writer =
        spawn(fn ->
          {:ok, _} = Quota.charge(key, digest, 8, 8)
          send(parent, :reserved)
          receive do: (:stop -> :ok)
        end)

      assert_receive :reserved, 1_000
      restart_quota()
      recover_now()
      server = BizKit.Cluster.Singleton.whereis_name(Quota)
      :erlang.trace(server, true, [:receive])
      on_exit(fn -> if Process.alive?(server), do: :erlang.trace(server, false, [:receive]) end)
      send(writer, :stop)
      assert_receive {:trace, ^server, :receive, {:DOWN, _, :process, ^writer, :normal}}, 1_000
      assert {:ok, reservation} = Quota.charge(key, "replacement", 8, 8)
      :ok = Quota.refund(reservation)
    end

    test "legacy and unreachable restored writers retain room until explicit settlement", %{
      key: key
    } do
      for legacy <- [true, false] do
        id = "unknown-#{key}-#{legacy}"
        scope = {key, legacy}
        digest = :crypto.hash(:sha256, id)
        node = "unreachable_quota_writer@invalid"

        record =
          if legacy do
            {:reserved, id, scope, digest, 8, Atom.to_string(node())}
          else
            {:reserved, id, scope, digest, 8, node, :erlang.term_to_binary(self())}
          end

        :ok =
          CoopSubstrate.Records.append_to_stream("evidence-quota", :any_version, [
            %EventStore.EventData{event_type: "EvidenceQuota", data: record}
          ])

        restart_quota()
        recover_now()
        recover_now()
        assert Quota.charge(scope, "other", 8, 8) == {:error, :quota_exceeded}
        assert Quota.refund({id, scope, digest, 8}) == :ok
        assert {:ok, reservation} = Quota.charge(scope, "other", 8, 8)
        :ok = Quota.refund(reservation)
      end
    end

    test "a peer writer retains capacity through recovery and a distribution disconnect", %{
      key: key
    } do
      alias BizKit.Cluster.Peers
      Peers.distribute!()
      {control, peer} = Peers.start!()
      Peers.mesh!([peer])
      root = Path.join(System.tmp_dir!(), "quota-peer-#{key}")
      :ok = :peer.call(control, Application, :put_env, [:coop_substrate, :artifact_dir, root])
      on_exit(fn -> File.rm_rf(root) end)
      bytes = "peer-#{key}"
      digest = :crypto.hash(:sha256, bytes)
      size = byte_size(bytes)
      writer = :peer.call(control, CoopSubstrate.QuotaWriter, :start, [self(), key, bytes])
      assert_receive {:writer_ready, ^writer}, 2_000
      restart_quota()
      recover_now()
      server = BizKit.Cluster.Singleton.whereis_name(Quota)
      :erlang.trace(server, true, [:receive])
      on_exit(fn -> if Process.alive?(server), do: :erlang.trace(server, false, [:receive]) end)
      true = Node.disconnect(peer)

      assert_receive {:trace, ^server, :receive, {:DOWN, _, :process, ^writer, :noconnection}},
                     2_000

      assert Quota.charge(key, "replacement", size, size) == {:error, :quota_exceeded}
      true = Node.connect(peer)
      Peers.mesh!([peer])
      recover_now()
      send(writer, :land)
      assert_receive {:writer_finished, ^writer, {:ok, ^digest}}, 2_000
      restart_quota()
      assert Quota.charge(key, digest, size, size) == {:ok, :held}
      assert Quota.charge(key, "replacement", 1, size) == {:error, :quota_exceeded}
    end

    defp recover_now do
      server = BizKit.Cluster.Singleton.whereis_name(Quota)
      send(server, :resolve_restored)
      :sys.get_state(server)
    end

    test "failed and refunded writes leave nothing behind", %{key: key} do
      {:ok, reservation} = Quota.charge(key, "a", 8, 8)
      assert Quota.refund(reservation) == :ok
      assert Quota.store(key, "b", 8, 8, fn -> {:error, :enospc} end) == {:error, :enospc}

      restart_quota()
      assert {:ok, _} = Quota.charge(key, "c", 8, 8)
    end
  end
end
