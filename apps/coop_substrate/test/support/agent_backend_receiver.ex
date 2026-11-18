defmodule CoopSubstrate.AgentBackendReceiver do
  @moduledoc false

  # The bridge starts a real receiver child but withholds its stdin until the
  # test releases it. There is no hold or kill operation in the wire protocol.
  @bridge ~S"""
  import json
  import select
  import signal
  import sqlite3
  import subprocess
  import sys
  from urllib.parse import quote

  mode, script, database = sys.argv[1:]
  command = [sys.executable, script]
  command += [database] if mode == "crash" else [mode, "--db", database]
  child = subprocess.Popen(command, stdin=subprocess.PIPE,
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE)

  def interrupted(signum, frame):
      raise SystemExit(128 + signum)

  signal.signal(signal.SIGTERM, interrupted)
  signal.signal(signal.SIGHUP, interrupted)
  try:
      print(json.dumps({"phase": "ready", "receiver_pid": child.pid}), flush=True)
      control = sys.stdin.buffer.readline(8193)
      if not control or len(control) > 8192:
          raise RuntimeError("missing or oversized test control")
      payload = b"" if mode == "init" else control.rstrip(b"\n")
      result = {"phase": "finished", "receiver_pid": child.pid}
      if mode == "crash":
          request = json.loads(payload)
          child.stdin.write(payload)
          child.stdin.close()
          child.stdin = None
          readable, _, _ = select.select([child.stderr], [], [], 10)
          if not readable or child.stderr.readline() != b"COMMITTED\n":
              raise RuntimeError("receiver did not acknowledge its committed test barrier")
          with sqlite3.connect("file:" + quote(database, safe="/") + "?mode=ro",
                               uri=True) as connection:
              connection.row_factory = sqlite3.Row
              row = connection.execute(
                  "SELECT * FROM backend_requests WHERE effect_id = ?",
                  (request["effect_id"],)).fetchone()
              count = connection.execute("SELECT COUNT(*) FROM backend_requests").fetchone()[0]
          result.update(committed=True, stored_binding=dict(row), allocation_count=count)
          child.kill()
          stdout, stderr = child.communicate(timeout=10)
          stderr = b"COMMITTED\n" + stderr
      else:
          stdout, stderr = child.communicate(payload, timeout=10)
      result.update(status=child.returncode, stdout=stdout.decode(), stderr=stderr.decode())
      print(json.dumps(result), flush=True)
  finally:
      if child.poll() is None:
          child.kill()
          child.wait(timeout=10)
  """

  def new_store do
    directory =
      Path.join(System.tmp_dir!(), "agent-backend-" <> CoopSubstrate.ULID.generate())

    File.mkdir!(directory)
    File.chmod!(directory, 0o700)
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(directory) end)
    initialize(%{directory: directory, db: Path.join(directory, "receiver.sqlite3")})
  end

  def initialize(store) do
    result = store |> start("init") |> finish(%{})

    %{
      "schema" => "bizkit.agent-backend-store.v1",
      "store_id" => store_id
    } = response = result.response

    true = result.status == 0 and map_size(response) == 2
    true = Regex.match?(~r/\Aagent-backend-store:[0-9a-f]{32}\z/, store_id)
    Map.merge(store, %{store_id: store_id, init_pid: result.receiver_pid})
  end

  def hold(store, request) do
    store |> start("request") |> Map.put(:request, request)
  end

  def release(pending), do: finish(pending, pending.request)
  def request(store, request), do: store |> hold(request) |> release()
  def crash_after_commit(store, request), do: store |> start("crash") |> finish(request)

  def evidence(name, effect_id, store_id, fields) do
    if directory = System.get_env("AGENT_BACKEND_EVIDENCE_DIR") do
      revision = System.fetch_env!("AGENT_LAUNCH_SOURCE_REVISION")

      evidence =
        Map.merge(fields, %{
          "schema" => "bizkit.agent-backend-signed-evidence.v1",
          "source_revision" => revision,
          "effect_id" => effect_id,
          "store_id" => store_id,
          "execution_started" => false,
          "termination_verified" => false
        })

      encoded = Jason.encode!(evidence, pretty: true)
      true = byte_size(encoded) <= 32_768
      suffix = Base.encode16(:crypto.hash(:sha256, effect_id <> store_id), case: :lower)
      File.mkdir_p!(directory)
      File.write!(Path.join(directory, "signed-#{name}-#{suffix}.json"), encoded <> "\n")
    end

    :ok
  end

  defp start(store, mode) do
    # Some narrower CI stages compile test/support without staging experiments.
    # Only a test invoking this helper requires Python and the receiver files.
    python = System.find_executable("python3") || raise "Python 3 is required for receiver tests"
    filename = if mode == "crash", do: "barrier_receiver.py", else: "receiver.py"

    script =
      Path.expand("../../../../experiments/agent_backend_receiver/#{filename}", __DIR__)

    unless File.regular?(script), do: raise("missing receiver fixture: #{script}")

    port =
      Port.open({:spawn_executable, python}, [
        :binary,
        :exit_status,
        :use_stdio,
        :stderr_to_stdout,
        {:line, 16_384},
        {:args, ["-c", @bridge, mode, script, store.db]}
      ])

    {:os_pid, bridge_pid} = Port.info(port, :os_pid)
    %{"phase" => "ready", "receiver_pid" => receiver_pid} = receive_line(port)
    true = is_integer(receiver_pid) and receiver_pid > 0 and receiver_pid != bridge_pid
    %{port: port, receiver_pid: receiver_pid, bridge_pid: bridge_pid}
  end

  defp finish(pending, request) do
    true = Port.command(pending.port, Jason.encode!(request) <> "\n")

    %{"phase" => "finished", "receiver_pid" => receiver_pid} =
      result =
      receive_line(pending.port)

    true = receiver_pid == pending.receiver_pid
    await_exit(pending.port)

    response =
      case result["stdout"] do
        "" -> nil
        encoded -> Jason.decode!(encoded)
      end

    %{
      response: response,
      status: result["status"],
      stdout: result["stdout"],
      stderr: result["stderr"],
      receiver_pid: receiver_pid,
      bridge_pid: pending.bridge_pid,
      committed: result["committed"],
      stored_binding: result["stored_binding"],
      allocation_count: result["allocation_count"]
    }
  end

  defp receive_line(port) do
    receive do
      {^port, {:data, {:eol, line}}} -> Jason.decode!(line)
      {^port, {:data, {:noeol, _}}} -> raise "oversized receiver bridge output"
      {^port, {:exit_status, status}} -> raise "receiver bridge exited early: #{status}"
    after
      15_000 -> raise "receiver bridge timed out"
    end
  end

  defp await_exit(port) do
    receive do
      {^port, {:exit_status, 0}} -> :ok
      {^port, {:exit_status, status}} -> raise "receiver bridge failed: #{status}"
      {^port, {:data, _}} -> raise "unexpected extra receiver bridge output"
    after
      15_000 -> raise "receiver bridge did not exit"
    end
  end
end
