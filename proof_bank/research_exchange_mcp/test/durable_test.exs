defmodule ResearchExchange.DurableTransportTest do
  use ExUnit.Case, async: true
  alias ResearchExchange.{Durable, Evidence, MCP, Server}
  @token String.duplicate("t", 32)
  @schema "research-exchange/bridge-rpc/v1"

  # These children deliberately replace the operator's Python executable to
  # exercise framing and failure handling. They never stand in for checker or
  # persistence acceptance; the bridge's separate tests use the real backend.
  defp child(body) do
    directory =
      Path.join(System.tmp_dir!(), "research-exchange-wire-#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    config = Path.join(directory, "operator.json")
    File.write!(config, "{}\n")
    File.chmod!(config, 0o600)
    executable = Path.join(directory, "transport-child")
    python = System.find_executable("python3")
    assert python != nil

    source =
      "#!#{python}\n" <>
        "import json, pathlib, sys\n" <>
        "for line in sys.stdin:\n" <>
        "    request = json.loads(line)\n" <>
        (body |> String.trim() |> String.split("\n") |> Enum.map_join("\n", &("    " <> &1))) <>
        "\n"

    File.write!(executable, source)
    File.chmod!(executable, 0o700)

    spec =
      Supervisor.child_spec(
        {Durable, %{config_path: config, python_executable: executable}},
        id: System.unique_integer([:positive])
      )

    {start_supervised!(spec), config}
  end

  defp echo do
    """
    result = {"request": request, "argv": sys.argv[1:]}
    print(json.dumps({"schema": request["schema"], "id": request["id"], "ok": True, "result": result}), flush=True)
    """
  end

  test "forwards only the approved RPC shape and fixes the executable arguments" do
    {pid, config} = child(echo())
    assert {:ok, authenticated} = Server.authenticate(pid, @token)

    assert authenticated["request"] == %{
             "schema" => @schema,
             "id" => 1,
             "op" => "authenticate",
             "token" => @token
           }

    script = Path.expand("../../research_exchange_bridge/stdio.py", __DIR__)
    assert authenticated["argv"] == ["-I", "-B", script, "--config", config]
    arguments = %{"id" => "receipt-1"}
    assert {:ok, called} = Server.call(pid, @token, "receipt_get", arguments)

    assert called["request"] == %{
             "schema" => @schema,
             "id" => 2,
             "op" => "call",
             "token" => @token,
             "tool" => "receipt_get",
             "arguments" => arguments
           }

    assert called["argv"] == authenticated["argv"]
  end

  test "known domain refusals keep the private connection usable" do
    {pid, _} =
      child("""
      if request["op"] == "call":
          response = {"schema": request["schema"], "id": request["id"], "ok": False, "error": "forbidden"}
      else:
          response = {"schema": request["schema"], "id": request["id"], "ok": True, "result": {"principal": "agent-a"}}
      print(json.dumps(response), flush=True)
      """)

    assert {:ok, %{"principal" => "agent-a"}} = Server.authenticate(pid, @token)
    assert {:error, :forbidden} = Server.call(pid, @token, "receipt_get", %{"id" => "private"})
    assert {:ok, %{"principal" => "agent-a"}} = Server.authenticate(pid, @token)
  end

  test "JSON null in backend receipts is preserved through the MCP encoder" do
    {pid, _} =
      child("""
      print(json.dumps({"schema": request["schema"], "id": request["id"], "ok": True, "result": {"optional": None}}), flush=True)
      """)

    assert {:ok, %{"optional" => nil} = result} = Server.authenticate(pid, @token)
    assert Evidence.canonical(result) == ~s({"optional":null})
  end

  test "malformed or unrenderable backend frames fail closed" do
    for response <- [
          "{\"schema\": request[\"schema\"], \"id\": request[\"id\"] + 1, \"ok\": True, \"result\": {}}",
          "{\"schema\": \"other-schema\", \"id\": request[\"id\"], \"ok\": True, \"result\": {}}",
          "{\"schema\": request[\"schema\"], \"id\": request[\"id\"], \"ok\": True, \"result\": {}, \"extra\": True}",
          "{\"schema\": request[\"schema\"], \"id\": request[\"id\"], \"ok\": True, \"result\": {\"float\": 1.5}}",
          "{\"schema\": request[\"schema\"], \"id\": request[\"id\"], \"ok\": True, \"result\": []}"
        ] do
      {pid, _} = child("print(json.dumps(#{response}), flush=True)")
      assert {:error, :bridge_protocol_error} = Server.authenticate(pid, @token)
      assert {:error, :bridge_unavailable} = Server.authenticate(pid, @token)
    end
  end

  test "duplicate JSON keys and oversized backend lines are refused" do
    for body <- [
          ~s|print('{"schema":"research-exchange/bridge-rpc/v1","id":1,"id":1,"ok":true,"result":{}}', flush=True)|,
          ~s|print("x" * 131073, flush=True)|
        ] do
      {pid, _} = child(body)
      assert {:error, :bridge_protocol_error} = Server.authenticate(pid, @token)
      assert {:error, :bridge_unavailable} = Server.authenticate(pid, @token)
    end
  end

  test "unregistered error strings never become atoms" do
    code = "unknown_bridge_error_#{System.unique_integer([:positive])}"
    assert_raise ArgumentError, fn -> String.to_existing_atom(code) end

    {pid, _} =
      child("""
      print(json.dumps({"schema": request["schema"], "id": request["id"], "ok": False, "error": #{Evidence.canonical(code)}}), flush=True)
      """)

    assert {:error, :bridge_protocol_error} = Server.authenticate(pid, @token)
    assert_raise ArgumentError, fn -> String.to_existing_atom(code) end
  end

  test "a duplicate old response cannot satisfy the next request" do
    {pid, _} =
      child("""
      response = json.dumps({"schema": request["schema"], "id": request["id"], "ok": True, "result": {"principal": "agent-a"}})
      print(response, flush=True)
      print(response, flush=True)
      """)

    assert {:ok, %{"principal" => "agent-a"}} = Server.authenticate(pid, @token)
    assert {:error, reason} = Server.authenticate(pid, @token)
    # The extra frame can arrive while idle or while awaiting the next reply.
    assert reason in [:bridge_unavailable, :bridge_protocol_error]
    assert {:error, :bridge_unavailable} = Server.authenticate(pid, @token)
  end

  test "exit and missing backend responses fail closed within the caller timeout" do
    {exited, _} = child("sys.exit(7)")
    assert {:error, :bridge_unavailable} = Server.authenticate(exited, @token)
    {silent, _} = child("sys.stdin.read()\nsys.exit(0)")
    assert {:error, :bridge_unavailable} = Server.authenticate(silent, @token)
    assert {:error, :bridge_unavailable} = Server.authenticate(silent, @token)
  end

  test "oversized and noncanonical input is refused before forwarding and the session survives" do
    {pid, _} = child(echo())

    assert {:error, :invalid_arguments} =
             Server.call(pid, @token, "proof_submit", %{
               "artifact" => String.duplicate("x", 131_073)
             })

    assert {:error, :invalid_arguments} =
             Server.call(pid, @token, "proof_submit", %{"generation" => 1.5})

    assert {:ok, result} = Server.authenticate(pid, @token)
    assert result["request"]["id"] == 1
  end

  test "direct worker, meter and administration messages cannot supply outcomes" do
    {pid, _} = child(echo())
    assert {:error, :forbidden} = Server.observe(pid, %{"outcome" => "checker_passed"}, "mac")
    assert {:error, :forbidden} = Server.observe_compute(pid, %{"cpu_milliseconds" => 1}, "mac")
    assert {:error, :forbidden} = Server.job(pid, "job-id", "worker-key")
    assert {:error, :forbidden} = Server.revoke(pid, "token-hash")
    assert {:ok, result} = Server.authenticate(pid, @token)
    assert result["request"]["id"] == 1
  end

  test "MCP modes retain the same four tools with explicit execution scope" do
    assert MCP.tools() == MCP.tools(:memory)
    memory = Map.new(MCP.tools(:memory), &{&1["name"], &1["description"]})
    durable = Map.new(MCP.tools(:durable), &{&1["name"], &1["description"]})
    pilot = Map.new(MCP.tools(:durable_pilot), &{&1["name"], &1["description"]})
    assert Map.keys(memory) == Map.keys(durable)
    assert Map.keys(memory) == Map.keys(pilot)
    assert map_size(durable) == 4
    assert memory["verification_request"] =~ "execution is disabled"
    assert durable["verification_request"] =~ "operator-provisioned library profile"
    assert durable["receipt_get"] =~ "durable"
    assert pilot["verification_request"] =~ "offline replay"
    assert pilot["receipt_get"] =~ "observation"

    {pid, _} = child(echo())

    initialize = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => "2025-11-25",
        "capabilities" => %{},
        "clientInfo" => %{"name" => "transport-test", "version" => "1"}
      }
    }

    {response, _} = MCP.handle(MCP.new(pid, @token, :durable), initialize)
    assert response["result"]["serverInfo"]["name"] == "research-exchange-durable-local"
    {response, _} = MCP.handle(MCP.new(pid, @token, :durable_pilot), initialize)
    assert response["result"]["serverInfo"]["name"] == "research-exchange-bounded"
  end

  test "mixed durable configurations are refused before either backend starts" do
    directory =
      Path.join(
        System.tmp_dir!(),
        "research-exchange-selection-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    marker = Path.join(directory, "bridge-started")
    pilot_marker = Path.join(directory, "pilot-started")
    executable = Path.join(directory, "selection-child")
    python = System.find_executable("python3")
    assert python != nil

    File.write!(
      executable,
      "#!#{python}\nimport pathlib\npathlib.Path(#{Evidence.canonical(marker)}).touch()\n"
    )

    File.chmod!(executable, 0o700)
    pilot_executable = Path.join(directory, "python3")

    File.write!(
      pilot_executable,
      "#!#{python}\nimport pathlib\npathlib.Path(#{Evidence.canonical(pilot_marker)}).touch()\n"
    )

    File.chmod!(pilot_executable, 0o700)
    bridge_config = Path.join(directory, "bridge.json")
    File.write!(bridge_config, "{}")
    database = Path.join(directory, "pilot.db")

    pilot = %{
      "durable_database" => database,
      "receipt_key_base64" => Base.encode64(String.duplicate("k", 32))
    }

    bridge = %{
      "backend" => "durable",
      "bridge_config" => bridge_config,
      "python_executable" => executable
    }

    for config <- [Map.merge(pilot, bridge), Map.put(pilot, "backend", "memory")] do
      path = Path.join(directory, "operator.json")
      File.write!(path, Evidence.canonical(config))
      launcher = Path.expand("../bin/stdio.exs", __DIR__)

      port =
        Port.open({:spawn_executable, System.find_executable("elixir")}, [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          {:args, [launcher]},
          {:env,
           [
             {~c"RESEARCH_EXCHANGE_CONFIG", String.to_charlist(path)},
             {~c"RESEARCH_EXCHANGE_TOKEN", String.to_charlist(@token)},
             {~c"PATH", String.to_charlist(directory <> ":" <> System.fetch_env!("PATH"))}
           ]}
        ])

      on_exit(fn -> if Port.info(port), do: Port.close(port) end)
      assert failed_start(port)
      refute File.exists?(marker)
      refute File.exists?(pilot_marker)
      refute File.exists?(database)
    end
  end

  defp failed_start(port) do
    receive do
      {^port, {:data, _}} -> failed_start(port)
      {^port, {:exit_status, code}} -> code != 0
    after
      5_000 -> flunk("ambiguous backend configuration did not fail before startup")
    end
  end
end
