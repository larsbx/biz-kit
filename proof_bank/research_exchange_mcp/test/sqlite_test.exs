defmodule ResearchExchange.SQLiteTest do
  use ExUnit.Case, async: true

  alias ResearchExchange.{AdapterTest, Evidence, Server}
  @token String.duplicate("a", 32)
  @worker String.duplicate("w", 32)

  setup do
    dir = Path.join(System.tmp_dir!(), "research-journal-#{System.unique_integer([:positive])}")
    File.mkdir!(dir)
    File.chmod!(dir, 0o700)
    on_exit(fn -> File.rm_rf!(dir) end)

    config = Map.put(AdapterTest.config(), :sqlite_path, Path.join(dir, "mcp.sqlite"))
    {:ok, pid} = Server.start_link(config)
    %{config: config, pid: pid}
  end

  defp reserve(p, submission_id, key) do
    Server.call(p, @token, "verification_request", %{
      "idempotency_key" => key,
      "submission_id" => submission_id
    })
  end

  defp get(p, id), do: Server.call(p, @token, "receipt_get", %{"id" => id})

  test "immutable identity, request replay and fencing survive competing launchers", %{
    pid: p,
    config: config
  } do
    assert {:ok, receipt} = AdapterTest.submit(p)
    id = receipt["payload"]["id"]
    {:ok, next} = Server.start_link(config)

    assert {:error, :journal_fenced} = AdapterTest.submit(p)
    assert {:ok, ^receipt} = AdapterTest.submit(next)
    assert {:ok, ^receipt} = get(next, id)
    args = AdapterTest.args()
    assert {:ok, ^receipt} = AdapterTest.submit(next, %{args | "idempotency_key" => "duplicate"})

    artifact = "substituted"

    assert {:error, :invalid_or_stale_binding} =
             AdapterTest.submit(next, %{args | "artifact" => artifact})

    assert {:error, :idempotency_conflict} =
             AdapterTest.submit(next, %{
               args
               | "artifact" => artifact,
                 "artifact_sha256" => Evidence.hash(artifact)
             })
  end

  test "only one durable reservation and one terminal outcome win concurrent requests", %{
    pid: p,
    config: config
  } do
    {:ok, submission} = AdapterTest.submit(p)
    id = submission["payload"]["id"]

    results =
      1..8
      |> Task.async_stream(fn _ -> reserve(p, id, "same") end)
      |> Enum.map(fn {:ok, result} -> result end)

    assert [{:ok, request}] = Enum.uniq(results)
    assert {:error, :already_requested} = reserve(p, id, "different")
    job_id = request["payload"]["id"]
    o = AdapterTest.observation(p, job_id)
    alternative = %{o | "outcome" => "checker_failed"}
    assert {:error, :metering_disabled} = Server.observe_compute(p, %{}, "")

    results =
      [o, alternative]
      |> Task.async_stream(&AdapterTest.signed(p, &1))
      |> Enum.map(fn {:ok, result} -> result end)

    assert [{:ok, terminal}] = Enum.filter(results, &match?({:ok, _}, &1))
    assert {:error, :observation_replay} in results
    outcome = terminal["payload"]["details"]["observations"]
    [winner] = Map.values(outcome)
    observed = if winner["outcome"] == o["outcome"], do: o, else: alternative
    assert terminal["payload"]["mathematical_acceptance"] == false
    assert terminal["payload"]["credit_issuance"] == false
    assert {:error, :reservation_closed} = Server.job(p, job_id, @worker)

    {:ok, next} = Server.start_link(config)
    assert {:ok, ^request} = reserve(next, id, "same")
    assert {:ok, ^terminal} = AdapterTest.signed(next, observed)
    assert {:ok, ^terminal} = get(next, job_id)
  end

  test "crashed worker and abruptly killed server fence stale capabilities", %{pid: p, config: c} do
    id = AdapterTest.queue(p)
    lost = AdapterTest.observation(p, id)
    :sys.replace_state(p, fn s -> put_in(s.config.clock, fn -> 1301 end) end)
    assert {:error, :invalid_observation} = AdapterTest.signed(p, lost)
    renewed = AdapterTest.observation(p, id)
    assert renewed["binding"]["reservation_version"] > lost["binding"]["reservation_version"]
    refute renewed["capability"] == lost["capability"]

    Process.unlink(p)
    monitor = Process.monitor(p)
    Process.exit(p, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^p, :killed}

    {:ok, next} = Server.start_link(c)
    assert {:error, :invalid_observation} = AdapterTest.signed(next, renewed)
    recovered = AdapterTest.observation(next, id)
    assert recovered["binding"]["reservation_version"] > renewed["binding"]["reservation_version"]

    assert {:error, :invalid_observation} =
             AdapterTest.signed(
               next,
               put_in(recovered, ["binding", "artifact_sha256"], "changed")
             )

    assert {:ok, _} = AdapterTest.signed(next, recovered)
  end

  test "current grant and snapshot are required on claim, record and replay", %{pid: p, config: c} do
    id = AdapterTest.queue(p)
    observation = AdapterTest.observation(p, id)
    newer = put_in(c.libraries["lean-core"]["policy_sha256"], String.duplicate("f", 64))
    {:ok, next} = Server.start_link(newer)
    assert {:error, :stale_reservation} = Server.job(next, id, @worker)
    assert {:error, :invalid_observation} = AdapterTest.signed(next, observation)
    assert {:error, :invalid_or_stale_binding} = AdapterTest.submit(next)

    :ok = Server.revoke(next, Evidence.hash(@token))
    {:ok, restarted} = Server.start_link(c)
    assert {:error, :unauthorized} = AdapterTest.submit(restarted)
    assert {:error, :unauthorized} = get(restarted, id)
    assert {:error, :stale_reservation} = Server.job(restarted, id, @worker)
    assert {:error, :invalid_observation} = AdapterTest.signed(restarted, observation)
  end

  test "a failed SQLite write leaves no acknowledged or partial admission", %{pid: p, config: c} do
    sql =
      "CREATE TRIGGER test_refuse_write BEFORE UPDATE OF snapshot ON mcp_journal_v1 " <>
        "BEGIN SELECT RAISE(ABORT, 'injected journal failure'); END"

    execute_sql(c.sqlite_path, sql)

    Process.unlink(p)
    monitor = Process.monitor(p)
    assert {:error, :journal_unavailable} = AdapterTest.submit(p)
    assert_receive {:DOWN, ^monitor, :process, ^p, :normal}

    execute_sql(c.sqlite_path, "DROP TRIGGER test_refuse_write")
    {:ok, next} = Server.start_link(c)
    assert {:ok, receipt} = AdapterTest.submit(next)
    assert receipt["payload"]["state_version"] == 1
    assert {:ok, ^receipt} = AdapterTest.submit(next)
  end

  defp execute_sql(path, statement) do
    code =
      "import sqlite3, sys; db = sqlite3.connect(sys.argv[1]); db.execute(sys.argv[2]); db.commit()"

    assert {"", 0} = System.cmd("python3", ["-I", "-c", code, path, statement])
  end
end
