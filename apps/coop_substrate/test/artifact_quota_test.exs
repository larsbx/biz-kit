defmodule CoopSubstrate.ArtifactQuotaTest do
  use ExUnit.Case, async: false
  alias CoopSubstrate.ArtifactCustody.Quota

  setup do: %{key: make_ref()}

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
    on_exit(fn -> :erlang.trace(server, false, [:receive]) end)

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
          {:ok, token} = Quota.charge(scope, digest, size, size)
          if landed, do: {:ok, ^digest} = Artifacts.put(bytes)
          send(parent, {:reserved, self(), token})
          receive do: (:stop -> :ok)
        end)

      assert_receive {:reserved, ^writer, token}, 1_000
      Process.exit(writer, :kill)
      # Observe delivery of the real monitor signal, then query the server
      # behind that handler. No sleeps or scheduler-dependent race window.
      assert_receive {:trace, ^server, :receive, {:DOWN, ^token, :process, ^writer, :killed}},
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
          {key, :alice, :project, :task},
          {key, :bob, :project, :task},
          {key, :alice, :other_project, :task},
          {key, :alice, :project, :other_task}
        ] do
      assert Quota.store(scope, "a", 8, 8, fn -> {:ok, "a"} end) == {:ok, "a"}
      assert Quota.charge(scope, "b", 1, 8) == {:error, :quota_exceeded}
    end
  end
end
