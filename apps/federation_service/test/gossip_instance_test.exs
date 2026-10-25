defmodule FederationService.GossipInstanceTest do
  use ExUnit.Case, async: false
  import FederationService.TestHelpers
  @moduletag timeout: 120_000
  @executable System.get_env("BIZKIT_GOSSIP_EXECUTABLE")
  if is_nil(@executable),
    do: @moduletag(skip: "build the optional iroh sidecar and set BIZKIT_GOSSIP_EXECUTABLE")

  defp read(port, prefix, buffer \\ "") do
    case String.split(buffer, "\n", parts: 2) do
      [first, rest] ->
        if String.starts_with?(first, prefix),
          do: String.replace_prefix(first, prefix, "") |> Jason.decode!(),
          else: read(port, prefix, rest)

      _ ->
        receive do
          {^port, {:data, bytes}} -> read(port, prefix, buffer <> bytes)
          {^port, {:exit_status, code}} -> flunk("gossip node exited #{code}: #{buffer}")
        after
          15_000 -> flunk("gossip node timed out: #{buffer}")
        end
    end
  end

  defp command(port, request) do
    Port.command(port, Jason.encode!(request) <> "\n")
    read(port, "RESULT ")
  end

  defp stop(port) do
    if Port.info(port) do
      Port.command(port, "{\"op\":\"stop\"}\n")

      receive do
        {^port, {:exit_status, _}} -> :ok
      after
        5000 -> Port.close(port)
      end
    end
  end

  defp start(dir, actor, settings) do
    file = dir <> "/settings.json"
    File.write!(file, Jason.encode!(settings))

    args =
      Enum.flat_map(:code.get_path(), fn p -> ["-pa", to_string(p)] end) ++
        [Path.join(__DIR__, "support/gossip_node.exs"), dir, actor, @executable, file]

    port =
      Port.open({:spawn_executable, System.find_executable("elixir")}, [
        :binary,
        :exit_status,
        :use_stdio,
        :stderr_to_stdout,
        args: args,
        env: [{~c"ERL_FLAGS", ~c"+S 2:2"}]
      ])

    {port, read(port, "READY ")}
  end

  defp eventually(fun, attempts \\ 150) do
    if fun.(),
      do: :ok,
      else:
        if(attempts > 0,
          do:
            (
              Process.sleep(100)
              eventually(fun, attempts - 1)
            ),
          else: flunk("event-driven gossip did not converge")
        )
  end

  test "independent iroh nodes subscribe to a scoped topic, exchange committed events and recover a partition" do
    dir = temp()
    a_dir = dir <> "/alpha"
    b_dir = dir <> "/beta"
    alpha = "https://alpha.example/actors/shop"
    beta = "https://beta.example/actors/shop"

    keys =
      for {directory, actor} <- [{a_dir, alpha}, {b_dir, beta}], into: %{} do
        File.mkdir_p!(directory)
        seed = :crypto.strong_rand_bytes(32)
        File.write!(directory <> "/endpoint.key", seed)
        File.chmod!(directory <> "/endpoint.key", 0o600)
        {public, _} = :crypto.generate_key(:eddsa, :ed25519, seed)
        {actor, Base.encode16(public, case: :lower)}
      end

    settings = %{
      scope: %{halaqa_id: "public-market", charter_hash: String.duplicate("a", 64), epoch: 1},
      publisher_keys: keys,
      bind: "127.0.0.1:0",
      peers: []
    }

    {a, address_a} = start(a_dir, alpha, Map.put(settings, :allowed_endpoints, [keys[beta]]))

    {b, address_b} =
      start(
        b_dir,
        beta,
        Map.merge(settings, %{allowed_endpoints: [keys[alpha]], peers: [address_a]})
      )

    on_exit(fn ->
      stop(a)
      stop(b)
      File.rm_rf!(dir)
    end)

    am = metadata(alpha)
    bm = metadata(beta)
    assert command(a, %{op: "publish", event: "a0", metadata: am, revision: 0})["ok"]
    assert command(b, %{op: "publish", event: "b0", metadata: bm, revision: 0})["ok"]

    for p <- [a, b] do
      eventually(fn -> length(command(p, %{op: "snapshot"})["listings"]) == 2 end)
      snapshot = command(p, %{op: "snapshot"})

      assert Enum.sort(Enum.map(snapshot["listings"], & &1["source"])) == [
               "alpha.example",
               "beta.example"
             ]

      assert snapshot["ledger"] == "locally-owned-signed-history" and snapshot["events"] == 1
    end

    round = command(a, %{op: "catchup", receiver: beta})["status"]
    assert is_binary(round)
    eventually(fn -> command(a, %{op: "catchup_status", round: round})["state"] == "complete" end)
    assert command(a, %{op: "catchup_status", round: round})["current"]

    assert command(b, %{op: "renew", id: bm["id"]})["ok"]

    eventually(fn ->
      Enum.any?(command(a, %{op: "snapshot"})["listings"], fn row ->
        row["actor"] == beta and row["freshness_source"] == "publisher_lease"
      end)
    end)

    assert command(b, %{op: "snapshot"})["events"] == 1

    assert command(a, %{op: "publish", event: "a1", metadata: metadata(alpha, 1), revision: 1})[
             "ok"
           ]

    eventually(fn ->
      Enum.any?(
        command(b, %{op: "snapshot"})["listings"],
        &(&1["actor"] == alpha and &1["metadata"]["revision"] == 1)
      )
    end)

    stop(b)

    assert command(a, %{op: "publish", event: "a2", metadata: metadata(alpha, 2), revision: 2})[
             "ok"
           ]

    assert command(a, %{op: "withdraw", event: "delete", id: am["id"]})["ok"]
    stop(a)
    bind_a = hd(address_a["addrs"])["Ip"]
    bind_b = hd(address_b["addrs"])["Ip"]

    {a2, address_a2} =
      start(a_dir, alpha, Map.merge(settings, %{allowed_endpoints: [keys[beta]], bind: bind_a}))

    {b2, _} =
      start(
        b_dir,
        beta,
        Map.merge(settings, %{allowed_endpoints: [keys[alpha]], peers: [address_a2], bind: bind_b})
      )

    on_exit(fn ->
      stop(a2)
      stop(b2)
    end)

    eventually(fn -> command(b2, %{op: "snapshot"})["withdrawn"] == 1 end)
    assert [%{"actor" => ^beta}] = command(b2, %{op: "snapshot"})["listings"]
    assert command(b2, %{op: "snapshot"})["ledger"] == "locally-owned-signed-history"
    assert command(a2, %{op: "snapshot"})["events"] == 4
    assert command(a2, %{op: "snapshot"})["completed_rounds"] == 1
    assert command(a2, %{op: "catchup_status", round: round})["state"] == "complete"
    refute command(a2, %{op: "catchup_status", round: round})["current"]

    assert [%{"freshness_source" => "publisher_lease", "stale" => false}] =
             command(a2, %{op: "snapshot"})["listings"]

    assert command(b2, %{op: "snapshot"})["events"] == 1

    withdrawal_round = command(a2, %{op: "catchup", receiver: beta})["status"]
    assert is_binary(withdrawal_round)

    eventually(fn ->
      command(a2, %{op: "catchup_status", round: withdrawal_round})["state"] == "complete"
    end)

    assert command(a2, %{op: "snapshot"})["completed_rounds"] == 2
  end
end
