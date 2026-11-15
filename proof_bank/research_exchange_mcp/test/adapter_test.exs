defmodule ResearchExchange.AdapterTest do
  use ExUnit.Case, async: true
  alias ResearchExchange.{Evidence, MCP, Server, Stdio}
  @token String.duplicate("a", 32)
  @other String.duplicate("b", 32)
  @receipt String.duplicate("r", 32)
  @worker String.duplicate("w", 32)
  @meter String.duplicate("m", 32)
  @revision String.duplicate("1", 40)
  @hash String.duplicate("2", 64)

  def config do
    grant = %{
      principal: "agent-a",
      expires: 2000,
      libraries: ["lean-core"],
      scopes: ["library:read", "proof:submit", "verification:request"]
    }

    lib = %{
      "id" => "lean-core",
      "revision" => @revision,
      "snapshot_sha256" => @hash,
      "environment_sha256" => String.duplicate("3", 64),
      "policy_sha256" => String.duplicate("4", 64),
      "generation" => 1,
      "engine" => "lean"
    }

    %{
      receipt_key: @receipt,
      worker_key: @worker,
      meter_key: @meter,
      tokens: %{
        Evidence.hash(@token) => grant,
        Evidence.hash(@other) => %{grant | principal: "agent-b"}
      },
      libraries: %{"lean-core" => lib, "private" => %{lib | "id" => "private"}},
      clock: fn -> 1000 end
    }
  end

  setup do
    {:ok, pid} = Server.start_link(config())
    %{server: pid}
  end

  def args do
    artifact = "-- UTF-8 artifact: αβγ é\ntheorem sample : True := True.intro\n"

    %{
      "idempotency_key" => "submit-1",
      "library" => "lean-core",
      "revision" => @revision,
      "snapshot_sha256" => @hash,
      "generation" => 1,
      "target" => "sample",
      "artifact" => artifact,
      "artifact_sha256" => Evidence.hash(artifact)
    }
  end

  def submit(pid, a \\ args()), do: Server.call(pid, @token, "proof_submit", a)

  def queue(pid) do
    {:ok, r} = submit(pid)

    {:ok, j} =
      Server.call(pid, @token, "verification_request", %{
        "submission_id" => r["payload"]["id"],
        "idempotency_key" => "verify-1"
      })

    j["payload"]["id"]
  end

  def observation(pid, id) do
    {:ok, j} = Server.job(pid, id, @worker)

    %{
      "job_id" => id,
      "binding" => j.binding,
      "capability" => j.capability,
      "outcome" => "checker_passed",
      "evidence_sha256" => @hash
    }
  end

  def signed(pid, o),
    do:
      Server.observe(
        pid,
        o,
        Evidence.mac(@worker, "research-exchange/verifier-observation/v1", o)
      )

  def rpc(method, p \\ %{}),
    do: %{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => p}

  def ready(pid, token \\ @token) do
    {_, s} =
      MCP.handle(
        MCP.new(pid, token),
        rpc("initialize", %{
          "protocolVersion" => "2025-11-25",
          "clientInfo" => %{"name" => "test", "version" => "1"},
          "capabilities" => %{}
        })
      )

    {nil, s} = MCP.handle(s, %{"jsonrpc" => "2.0", "method" => "notifications/initialized"})
    s
  end

  defp stdio_request(port, id, method, params \\ %{}) do
    request = rpc(method, params) |> Map.put("id", id)
    assert Port.command(port, Evidence.canonical(request) <> "\n")

    response =
      receive do
        {^port, {:data, {:eol, json}}} -> :json.decode(json)
        {^port, {:data, {:noeol, _}}} -> flunk("stdio response exceeds the line bound")
        {^port, {:exit_status, status}} -> flunk("stdio child exited with status #{status}")
      after
        10_000 -> flunk("stdio response timeout for #{method} (id #{id})")
      end

    assert response["jsonrpc"] == "2.0"
    assert response["id"] == id
    response
  end

  defp successful_tool(response) do
    assert %{
             "result" => %{
               "isError" => false,
               "structuredContent" => result,
               "content" => content
             }
           } = response

    assert content == [%{"type" => "text", "text" => Evidence.canonical(result)}]
    result
  end

  defp assert_inert_receipt(receipt) do
    assert Evidence.verify_receipt?(receipt, @receipt)
    assert receipt["payload"]["mathematical_acceptance"] == false
    assert receipt["payload"]["credit_issuance"] == false
  end

  test "discovery authenticates and filters inaccessible libraries", %{server: p} do
    assert {:error, :unauthorized} = Server.call(p, nil, "library_discover", %{})

    assert {:ok, %{"libraries" => [%{"id" => "lean-core"}], "benefits" => b}} =
             Server.call(p, @token, "library_discover", %{})

    assert b["issuance_enabled"] == false
    assert b["ecosystem_credits"] == "nonmonetary-policy-pending"
  end

  test "expires and revokes credentials before replay", %{server: p} do
    assert {:ok, _} = submit(p)
    :ok = Server.revoke(p, Evidence.hash(@token))
    assert {:error, :unauthorized} = submit(p)
    c = config() |> Map.put(:clock, fn -> 2000 end)
    {:ok, expired} = Server.start_link(c)
    assert {:error, :unauthorized} = Server.authenticate(expired, @token)
  end

  test "capabilities are scoped independently of library visibility" do
    c = config() |> put_in([:tokens, Evidence.hash(@token), :scopes], ["library:read"])
    {:ok, p} = Server.start_link(c)
    assert {:error, :forbidden} = submit(p)
    assert {:ok, _} = Server.call(p, @token, "library_discover", %{})
  end

  test "denies unauthorized library without existence disclosure", %{server: p} do
    for id <- ["private", "does-not-exist"] do
      assert {:error, :forbidden} = submit(p, %{args() | "library" => id})
    end
  end

  test "rejects contributor verifier, identity and settlement authority fields", %{server: p} do
    for field <- [
          "trusted",
          "success",
          "contributor",
          "worker",
          "stop_ack",
          "settlement",
          "credits"
        ] do
      assert {:error, :invalid_or_stale_binding} = submit(p, Map.put(args(), field, true))
    end

    for tool <- ["accept", "settle", "verifier_result", "compute_observation", "issue_credits"] do
      assert {:error, :unknown_tool} = Server.call(p, @token, tool, %{})
    end
  end

  test "rejects stale revision, snapshot, generation, and artifact", %{server: p} do
    for {field, value} <- [
          {"revision", String.duplicate("0", 40)},
          {"snapshot_sha256", String.duplicate("0", 64)},
          {"generation", 0},
          {"generation", 1.0},
          {"artifact_sha256", @hash}
        ] do
      assert {:error, :invalid_or_stale_binding} = submit(p, Map.put(args(), field, value))
    end
  end

  test "all admitted evidence binds exact source, artifact, principal and policy", %{server: p} do
    {:ok, r} = submit(p)
    b = r["payload"]["binding"]
    assert b["contributor"] == "agent-a"
    assert b["source_revision"] == @revision
    assert b["source_snapshot_sha256"] == @hash
    assert b["artifact_sha256"] == args()["artifact_sha256"]
    assert b["environment_sha256"] == config().libraries["lean-core"]["environment_sha256"]
    assert b["policy_sha256"] == config().libraries["lean-core"]["policy_sha256"]
    assert b["core"] == Server.core()
    assert Evidence.verify_receipt?(r, @receipt)
    assert r["payload"]["mathematical_acceptance"] == false
  end

  test "canonical receipt rejects mutation and wrong signing key", %{server: p} do
    {:ok, r} = submit(p)

    refute Evidence.verify_receipt?(
             put_in(r, ["payload", "binding", "contributor"], "agent-b"),
             @receipt
           )

    refute Evidence.verify_receipt?(r, @worker)
    assert Evidence.canonical(%{"z" => 1, "a" => [true, "é"]}) == ~s({"a":[true,"é"],"z":1})
    assert Evidence.canonical(%{"missing" => nil}) == ~s({"missing":null})

    assert Evidence.hash("abc") ==
             "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
  end

  test "exact retry returns original receipt; changed request conflicts", %{server: p} do
    {:ok, r} = submit(p)
    assert {:ok, ^r} = submit(p)
    assert {:error, :idempotency_conflict} = submit(p, %{args() | "target" => "changed"})

    assert {:error, :idempotency_conflict} =
             Server.call(p, @token, "verification_request", %{
               "submission_id" => r["payload"]["id"],
               "idempotency_key" => "submit-1"
             })
  end

  test "another identity cannot read or verify a submission", %{server: p} do
    {:ok, r} = submit(p)
    id = r["payload"]["id"]
    assert {:error, :not_found} = Server.call(p, @other, "receipt_get", %{"id" => id})

    assert {:error, :not_found} =
             Server.call(p, @other, "verification_request", %{
               "submission_id" => id,
               "idempotency_key" => "steal"
             })
  end

  test "shared-server wire decoding refuses another principal's existing records", %{server: p} do
    # Two ordinary stdio children have separate stores. Share one server here so
    # the refused records actually exist, while exercising the JSON wire decoder
    # with two independently authenticated MCP sessions.
    owner = ready(p)
    other = ready(p, @other)

    {submitted, _} =
      Stdio.decode(
        owner,
        Evidence.canonical(rpc("tools/call", %{"name" => "proof_submit", "arguments" => args()}))
      )

    submission = successful_tool(submitted)
    submission_id = submission["payload"]["id"]
    request = %{"submission_id" => submission_id, "idempotency_key" => "owner-verify"}

    {queued, _} =
      Stdio.decode(
        owner,
        Evidence.canonical(
          rpc("tools/call", %{"name" => "verification_request", "arguments" => request})
        )
      )

    job = successful_tool(queued)
    job_id = job["payload"]["id"]

    for {tool, a} <- [
          {"receipt_get", %{"id" => submission_id}},
          {"receipt_get", %{"id" => job_id}},
          {"verification_request", %{request | "idempotency_key" => "other-verify"}}
        ] do
      {response, _} =
        Stdio.decode(
          other,
          Evidence.canonical(rpc("tools/call", %{"name" => tool, "arguments" => a}))
        )

      assert response["result"] == %{
               "content" => [%{"type" => "text", "text" => "not_found"}],
               "isError" => true
             }
    end

    for {id, expected} <- [{submission_id, submission}, {job_id, job}] do
      {response, _} =
        Stdio.decode(
          owner,
          Evidence.canonical(
            rpc("tools/call", %{"name" => "receipt_get", "arguments" => %{"id" => id}})
          )
        )

      assert successful_tool(response) == expected
      assert_inert_receipt(expected)
    end
  end

  test "concurrent identical requests reserve exactly once", %{server: p} do
    {:ok, r} = submit(p)
    a = %{"submission_id" => r["payload"]["id"], "idempotency_key" => "parallel"}

    results =
      1..16
      |> Task.async_stream(fn _ -> Server.call(p, @token, "verification_request", a) end)
      |> Enum.to_list()

    assert length(Enum.uniq(results)) == 1

    assert {:error, :already_requested} =
             Server.call(p, @token, "verification_request", %{a | "idempotency_key" => "new"})
  end

  test "worker access and forged observations fail", %{server: p} do
    id = queue(p)
    assert {:error, :unauthorized} = Server.job(p, id, @token)
    o = observation(p, id)

    for key <- [@token, @receipt, @meter] do
      assert {:error, :invalid_observation} =
               Server.observe(
                 p,
                 o,
                 Evidence.mac(key, "research-exchange/verifier-observation/v1", o)
               )
    end
  end

  test "valid worker observation records evidence once without acceptance", %{server: p} do
    id = queue(p)
    o = observation(p, id)
    assert {:ok, r} = signed(p, o)
    assert r["payload"]["status"] == "verifier_observation_recorded"
    refute r["payload"]["mathematical_acceptance"]
    refute r["payload"]["credit_issuance"]
    assert {:error, :observation_replay} = signed(p, o)
  end

  test "signed observation with any substituted source binding fails", %{server: p} do
    id = queue(p)
    o = observation(p, id)

    for field <- [
          "contributor",
          "source_revision",
          "source_snapshot_sha256",
          "target",
          "artifact_sha256",
          "environment_sha256",
          "policy_sha256",
          "submission_id",
          "generation",
          "core"
        ] do
      forged = put_in(o, ["binding", field], "substituted")
      assert {:error, :invalid_observation} = signed(p, forged)
    end
  end

  test "capability cannot cross jobs or process restarts", %{server: p} do
    id = queue(p)
    o = observation(p, id)
    {:ok, p2} = Server.start_link(config())
    id2 = queue(p2)
    refute id == id2
    assert {:error, :invalid_observation} = signed(p2, o)
    assert {:error, :invalid_observation} = signed(p2, %{o | "job_id" => id2})
  end

  test "expired verification capability is fenced", %{server: p} do
    id = queue(p)
    o = observation(p, id)
    :sys.replace_state(p, fn s -> put_in(s.config.clock, fn -> 1300 end) end)
    assert {:error, :invalid_observation} = signed(p, o)
  end

  test "policy and environment changes fence pending jobs", %{server: p} do
    id = queue(p)
    o = observation(p, id)

    :sys.replace_state(p, fn s ->
      put_in(s.config.libraries["lean-core"]["environment_sha256"], @hash)
    end)

    assert {:error, :invalid_observation} = signed(p, o)
  end

  test "malformed observations cannot crash the server", %{server: p} do
    id = queue(p)
    o = observation(p, id)

    for bad <- [
          nil,
          %{},
          %{o | "outcome" => 1.5},
          %{o | "capability" => []},
          %{o | "binding" => %{"float" => 1.5}}
        ] do
      assert {:error, :invalid_observation} = Server.observe(p, bad, "forged")
    end

    assert Process.alive?(p)
  end

  test "compute observations require independent authority and never settle", %{server: p} do
    id = queue(p)

    o =
      observation(p, id)
      |> Map.drop(["outcome", "evidence_sha256"])
      |> Map.merge(%{"cpu_milliseconds" => 99, "observation_sha256" => @hash})

    domain = "research-exchange/compute-observation/v1"

    assert {:error, :invalid_observation} =
             Server.observe_compute(p, o, Evidence.mac(@worker, domain, o))

    assert {:ok, r} = Server.observe_compute(p, o, Evidence.mac(@meter, domain, o))
    assert r["payload"]["status"] == "compute_observation_recorded"
    refute r["payload"]["credit_issuance"]

    assert {:error, :observation_replay} =
             Server.observe_compute(p, o, Evidence.mac(@meter, domain, o))

    assert {:ok, combined} = signed(p, observation(p, id))
    assert map_size(combined["payload"]["details"]["observations"]) == 2
    refute Evidence.canonical(combined) =~ o["capability"]
  end

  test "Quint catalog submissions use the same exact source bindings" do
    c = config() |> put_in([:libraries, "lean-core", "engine"], "quint")
    {:ok, p} = Server.start_link(c)

    a = %{
      args()
      | "artifact" => "module demo {}",
        "artifact_sha256" => Evidence.hash("module demo {}")
    }

    assert {:ok, _} = submit(p, a)
    :sys.replace_state(p, fn s -> put_in(s.config.libraries["lean-core"]["generation"], 2) end)
    assert {:error, :invalid_or_stale_binding} = submit(p, a)
  end

  test "bounded artifacts and malformed client values do not crash", %{server: p} do
    for artifact <- ["", String.duplicate("x", 65537), 1, nil, ["code"]] do
      assert {:error, :invalid_or_stale_binding} = submit(p, %{args() | "artifact" => artifact})
    end

    for value <- [nil, [], true, %{}, 1] do
      assert {:error, _} = Server.call(p, @token, "proof_submit", value)
    end

    assert Process.alive?(p)
  end

  test "state cap includes unique retry keys for identical artifacts", %{server: p} do
    for i <- 1..256 do
      assert {:ok, _} = submit(p, %{args() | "idempotency_key" => "key-#{i}"})
    end

    assert {:error, :capacity} = submit(p, %{args() | "idempotency_key" => "key-overflow"})
  end

  test "distinct immutable submissions stop at the process capacity", %{server: p} do
    for i <- 1..128 do
      assert {:ok, _} =
               submit(p, %{args() | "target" => "target-#{i}", "idempotency_key" => "submit-#{i}"})
    end

    assert {:error, :capacity} =
             submit(p, %{args() | "target" => "overflow", "idempotency_key" => "overflow"})
  end

  test "MCP lifecycle rejects premature calls and advertises only bounded tools", %{server: p} do
    {r, _} = MCP.handle(MCP.new(p, @token), rpc("tools/list"))
    assert r["error"]["code"] == -32002
    {r, _} = MCP.handle(ready(p), rpc("tools/list"))

    assert Enum.map(r["result"]["tools"], & &1["name"]) == [
             "library_discover",
             "proof_submit",
             "receipt_get",
             "verification_request"
           ]

    {r, _} =
      MCP.handle(ready(p), rpc("tools/call", %{"name" => "proof_submit", "arguments" => args()}))

    refute r["result"]["isError"]
    assert r["result"]["structuredContent"]["payload"]["binding"]["contributor"] == "agent-a"
  end

  test "MCP never exposes tool names without authentication", %{server: p} do
    {r, _} = MCP.handle(MCP.new(p, "wrong"), rpc("tools/list"))
    assert r["error"]["code"] == -32001
    refute Evidence.canonical(r) =~ "proof_submit"
  end

  test "notifications cannot submit effects and unknown tools cannot accept", %{server: p} do
    s = ready(p)
    n = rpc("tools/call", %{"name" => "proof_submit", "arguments" => args()}) |> Map.delete("id")
    assert {nil, ^s} = MCP.handle(s, n)

    {r, _} =
      MCP.handle(s, rpc("tools/call", %{"name" => "accept", "arguments" => %{"trusted" => true}}))

    assert r["error"]["code"] == -32602
  end

  test "MCP negotiates its supported version and supports omitted empty arguments", %{server: p} do
    {r, s} =
      MCP.handle(
        MCP.new(p, @token),
        rpc("initialize", %{
          "protocolVersion" => "future-version",
          "clientInfo" => %{"name" => "test", "version" => "1"},
          "capabilities" => %{}
        })
      )

    assert r["result"]["protocolVersion"] == "2025-11-25"
    {nil, s} = MCP.handle(s, %{"jsonrpc" => "2.0", "method" => "notifications/initialized"})
    {r, _} = MCP.handle(s, rpc("tools/call", %{"name" => "library_discover"}))
    refute r["result"]["isError"]

    assert {nil, _} =
             MCP.handle(MCP.new(p, "wrong"), %{
               "jsonrpc" => "2.0",
               "method" => "notifications/initialized"
             })
  end

  test "wire parser rejects duplicate keys, batches, floats and oversized data", %{server: p} do
    s = ready(p)

    for bytes <- [~s({"jsonrpc":"2.0","id":1,"id":2,"method":"ping"}), "{", ~s({"x":1} trailing)] do
      {r, _} = Stdio.decode(s, bytes)
      assert r["error"]["code"] == -32700
    end

    for bytes <- ["[]", ~s({"jsonrpc":"2.0","id":1.5,"method":"ping"})] do
      {r, _} = Stdio.decode(s, bytes)
      assert r["error"]["code"] == -32600
    end

    {r, _} = Stdio.decode(s, String.duplicate("x", 131_073))
    assert r["error"]["code"] == -32600
    {r, _} = Stdio.decode(s, Evidence.canonical(rpc("ping")))
    assert r["result"] == %{}

    {r, _} = Stdio.decode(s, ~s({"jsonrpc":"2.0","id":null,"method":"ping"}))
    assert r["id"] == nil
    assert Evidence.canonical(r) =~ ~s("id":null)
  end

  test "actual UTF-8 stdio subprocess completes all four tools and enforces byte limits" do
    dir = Path.join(System.tmp_dir!(), "research-exchange-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    path = Path.join(dir, "operator.json")
    c = put_in(config(), [:tokens, Evidence.hash(@token), :principal], "agent-é-α")

    tokens =
      Map.new(c.tokens, fn {h, g} ->
        {h,
         %{
           "principal" => g.principal,
           "expires" => System.system_time(:second) + 300,
           "libraries" => g.libraries,
           "scopes" => g.scopes
         }}
      end)

    raw = %{
      "libraries" => c.libraries,
      "tokens" => tokens,
      "receipt_key_base64" => Base.encode64(@receipt),
      "worker_key_base64" => Base.encode64(@worker),
      "meter_key_base64" => Base.encode64(@meter)
    }

    File.write!(path, Evidence.canonical(raw))
    File.chmod!(path, 0o600)
    script = Path.expand("../bin/stdio.exs", __DIR__)

    port =
      Port.open({:spawn_executable, System.find_executable("elixir")}, [
        :binary,
        :exit_status,
        {:line, 131_072},
        {:args, [script]},
        {:env,
         [
           {~c"RESEARCH_EXCHANGE_CONFIG", String.to_charlist(path)},
           {~c"RESEARCH_EXCHANGE_TOKEN", String.to_charlist(@token)}
         ]}
      ])

    on_exit(fn -> if Port.info(port), do: Port.close(port) end)

    initialized =
      stdio_request(port, 1, "initialize", %{
        "protocolVersion" => "2025-11-25",
        "clientInfo" => %{"name" => "wire", "version" => "1"},
        "capabilities" => %{}
      })

    assert initialized["result"]["protocolVersion"] == "2025-11-25"

    assert Port.command(
             port,
             Evidence.canonical(%{"jsonrpc" => "2.0", "method" => "notifications/initialized"}) <>
               "\n"
           )

    listed = stdio_request(port, 2, "tools/list")

    assert Enum.map(listed["result"]["tools"], & &1["name"]) == [
             "library_discover",
             "proof_submit",
             "receipt_get",
             "verification_request"
           ]

    call = fn id, tool, a ->
      stdio_request(port, id, "tools/call", %{"name" => tool, "arguments" => a})
    end

    discovered = call.(3, "library_discover", %{}) |> successful_tool()

    reviewed_core =
      Path.expand("../CORE_SNAPSHOT.json", __DIR__) |> File.read!() |> :json.decode()

    assert discovered["libraries"] == [c.libraries["lean-core"]]
    assert discovered["core"] == reviewed_core
    assert Server.core() == reviewed_core
    assert discovered["benefits"]["issuance_enabled"] == false

    submission = call.(4, "proof_submit", args()) |> successful_tool()
    assert_inert_receipt(submission)
    assert submission["payload"]["status"] == "submitted"
    submission_id = submission["payload"]["id"]

    binding = %{
      "contributor" => c.tokens[Evidence.hash(@token)].principal,
      "library" => "lean-core",
      "engine" => "lean",
      "source_revision" => @revision,
      "source_snapshot_sha256" => @hash,
      "generation" => 1,
      "target" => args()["target"],
      "artifact_sha256" => args()["artifact_sha256"],
      "environment_sha256" => c.libraries["lean-core"]["environment_sha256"],
      "policy_sha256" => c.libraries["lean-core"]["policy_sha256"],
      "core" => reviewed_core
    }

    assert submission["payload"]["binding"] == binding
    assert call.(5, "proof_submit", args()) |> successful_tool() == submission

    conflict = call.(6, "proof_submit", %{args() | "target" => "changed"})
    assert conflict["result"]["isError"] == true

    assert conflict["result"]["content"] == [
             %{"type" => "text", "text" => "idempotency_conflict"}
           ]

    request = %{"submission_id" => submission_id, "idempotency_key" => "verify-1"}
    cross_tool = call.(7, "verification_request", %{request | "idempotency_key" => "submit-1"})
    assert cross_tool["result"]["isError"] == true

    assert cross_tool["result"]["content"] == [
             %{"type" => "text", "text" => "idempotency_conflict"}
           ]

    job = call.(8, "verification_request", request) |> successful_tool()
    assert_inert_receipt(job)
    assert job["payload"]["status"] == "queued_execution_disabled"

    assert job["payload"]["details"] == %{
             "reservation" => "memory-only-capacity-slot",
             "credits_issued" => 0
           }

    job_id = job["payload"]["id"]
    refute job_id == submission_id
    job_binding = job["payload"]["binding"]
    assert Map.take(job_binding, Map.keys(binding)) == binding

    assert Enum.sort(Map.keys(job_binding)) ==
             Enum.sort(Map.keys(binding) ++ ["submission_id", "nonce", "boot", "expires_at"])

    assert job_binding["submission_id"] == submission_id
    assert job_binding["nonce"] =~ ~r/\A[0-9a-f]{64}\z/
    assert job_binding["boot"] =~ ~r/\A[0-9a-f]{32}\z/
    assert is_integer(job_binding["expires_at"])
    assert job_binding["expires_at"] > job["payload"]["recorded_at"]
    assert call.(9, "verification_request", request) |> successful_tool() == job

    duplicate =
      call.(10, "verification_request", %{request | "idempotency_key" => "verify-again"})

    assert duplicate["result"]["isError"] == true
    assert duplicate["result"]["content"] == [%{"type" => "text", "text" => "already_requested"}]

    read_submission = call.(11, "receipt_get", %{"id" => submission_id}) |> successful_tool()
    read_job = call.(12, "receipt_get", %{"id" => job_id}) |> successful_tool()
    assert read_submission == submission
    assert read_job == job
    assert_inert_receipt(read_submission)
    assert_inert_receipt(read_job)

    unavailable = call.(13, "accept", %{"trusted" => true})
    assert unavailable["error"]["code"] == -32602

    oversized = Evidence.canonical(rpc("ping", %{"padding" => String.duplicate("α", 65_537)}))
    assert byte_size(oversized) > 131_072
    assert Port.command(port, oversized <> "\n")

    receive do
      {^port, {:data, {:eol, json}}} ->
        assert json =~ ~s("id":null)
        {error, _, ""} = :json.decode(json, :ok, %{null: nil})
        assert error["id"] == nil
        assert error["error"]["code"] == -32600

      other ->
        flunk("unexpected oversized-frame response #{inspect(other)}")
    after
      10_000 -> flunk("oversized UTF-8 frame was not refused")
    end

    if Port.info(port), do: Port.close(port)
  end
end
