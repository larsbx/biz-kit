defmodule CoopSubstrate.AgentLocalWorker do
  @moduledoc false

  # This test bridge observes an actual worker independently of its provider's
  # receipt. Its pidfd is used only for observation; provider termination uses
  # a separate pidfd bound to the retained fixed-worker argv/nonce and identity.
  @bridge ~S"""
  import json
  import os
  from pathlib import Path
  import select
  import signal
  import subprocess
  import sys

  mode, script, database = sys.argv[1:]
  provider = str(Path(script).with_name("provider.py"))
  command = [sys.executable, script]
  command += [database, "after_work"] if mode == "crash" else [mode, "--db", database]
  child = subprocess.Popen(command, stdin=subprocess.PIPE,
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE)
  held_fd = None

  def interrupted(signum, frame):
      raise SystemExit(128 + signum)

  def lookup(request):
      query = {key: request[key] for key in ("schema", "store_id", "effect_id")}
      query["operation"] = "lookup"
      completed = subprocess.run([sys.executable, provider, "request", "--db", database],
                                 input=json.dumps(query).encode(), capture_output=True, timeout=10)
      if completed.returncode:
          raise RuntimeError("independent provider lookup failed")
      return json.loads(completed.stdout)

  def observe(response):
      identity = response.get("worker_identity")
      if identity is None:
          return None, {"live": False, "identity_present": False}
      pid = identity["pid"]
      fd = None
      try:
          fd = os.pidfd_open(pid)
          fields = Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()
          boot = Path("/proc/sys/kernel/random/boot_id").read_text().strip()
          matched = boot == identity["boot_id"] and int(fields[19]) == identity["start_ticks"]
          poller = select.poll()
          poller.register(fd, select.POLLIN)
          live = matched and not poller.poll(0) and fields[0] != "Z"
          observation = {"live": live, "identity_present": True, "identity_matched": matched,
                         "worker_identity": identity, "proc_state": fields[0],
                         "pidfd_exit_ready": bool(poller.poll(0))}
          if not matched:
              os.close(fd)
              fd = None
          return fd, observation
      except (OSError, ValueError, IndexError):
          if fd is not None:
              os.close(fd)
          return None, {"live": False, "identity_present": True, "identity_matched": False}

  signal.signal(signal.SIGTERM, interrupted)
  signal.signal(signal.SIGHUP, interrupted)
  try:
      print(json.dumps({"phase": "ready", "manager_pid": child.pid}), flush=True)
      control = sys.stdin.buffer.readline(8193)
      if not control or len(control) > 8192:
          raise RuntimeError("missing or oversized test control")
      payload = b"" if mode == "init" else control.rstrip(b"\n")
      request = {} if mode == "init" else json.loads(payload)
      result = {"phase": "finished", "manager_pid": child.pid}
      if request.get("operation") == "terminate":
          held_fd, result["before_termination"] = observe(lookup(request))
      if mode == "crash":
          child.stdin.write(payload)
          child.stdin.close()
          child.stdin = None
          readable, _, _ = select.select([child.stderr], [], [], 10)
          if not readable or child.stderr.readline() != b"WORKED\n":
              raise RuntimeError("manager did not reach the actual-work response barrier")
          observed = lookup(request)
          if observed["work_count"] != 1 or observed["execution_started"] is not True:
              raise RuntimeError("worker did not perform its fixed workload")
          child.kill()
          stdout, stderr = child.communicate(timeout=10)
          stderr = b"WORKED\n" + stderr
          held_fd, result["kernel_observation"] = observe(observed)
          result["observed_before_crash"] = observed
      else:
          stdout, stderr = child.communicate(payload, timeout=10)
      if held_fd is not None and request.get("operation") == "terminate":
          poller = select.poll()
          poller.register(held_fd, select.POLLIN)
          result["kernel_exit_observed"] = any(event & (select.POLLIN | select.POLLHUP)
                                                for _, event in poller.poll(2000))
      if stdout and child.returncode == 0 and "kernel_observation" not in result:
          observed_fd, result["kernel_observation"] = observe(json.loads(stdout))
          if observed_fd is not None:
              os.close(observed_fd)
      result.update(status=child.returncode, stdout=stdout.decode(), stderr=stderr.decode())
      print(json.dumps(result), flush=True)
  finally:
      if held_fd is not None:
          os.close(held_fd)
      if child.poll() is None:
          child.kill()
          child.wait(timeout=10)
  """

  def new_store(effect_id) do
    directory = Path.join(System.tmp_dir!(), "alw-" <> CoopSubstrate.ULID.generate())
    File.mkdir!(directory)
    File.chmod!(directory, 0o700)
    base = %{directory: directory, db: Path.join(directory, "worker.sqlite3")}
    result = base |> start("init") |> finish(%{})

    %{"schema" => "bizkit.agent-local-worker-store.v1", "store_id" => store_id} =
      result.response

    true = result.status == 0 and map_size(result.response) == 2
    true = Regex.match?(~r/\Aagent-backend-store:[0-9a-f]{32}\z/, store_id)
    store = Map.put(base, :store_id, store_id)

    ExUnit.Callbacks.on_exit(fn ->
      # Termination is idempotent. Preserve diagnostics if cleanup cannot prove
      # a known worker's exit; the fixed child also has its own bounded lifetime.
      stopped = request(store, command(store, effect_id, "terminate"))

      if stopped.status == 0 and
           (stopped.response["termination_verified"] or
              stopped.response["execution_started"] == false) do
        File.rm_rf!(directory)
      end
    end)

    store
  end

  def command(store, effect_id, operation) when operation in ~w(fence lookup terminate) do
    %{
      "schema" => "bizkit.agent-local-worker-request.v1",
      "operation" => operation,
      "store_id" => store.store_id,
      "effect_id" => effect_id
    }
  end

  def hold(store, request), do: store |> start("request") |> Map.put(:request, request)
  def release(pending), do: finish(pending, pending.request)
  def request(store, request), do: store |> hold(request) |> release()
  def crash_after_work(store, request), do: store |> start("crash") |> finish(request)

  def evidence(name, effect_id, store_id, fields) do
    if directory = System.get_env("AGENT_LOCAL_WORKER_EVIDENCE_DIR") do
      evidence =
        Map.merge(fields, %{
          "schema" => "bizkit.agent-local-worker-signed-evidence.v1",
          "source_revision" => System.fetch_env!("AGENT_LAUNCH_SOURCE_REVISION"),
          "effect_id" => effect_id,
          "store_id" => store_id
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
    python =
      System.find_executable("python3") || raise "Python 3 is required for local worker tests"

    filename = if mode == "crash", do: "barrier_provider.py", else: "provider.py"
    script = Path.expand("../../../../experiments/agent_local_worker/#{filename}", __DIR__)
    unless File.regular?(script), do: raise("missing local worker fixture: #{script}")

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
    %{"phase" => "ready", "manager_pid" => manager_pid} = receive_line(port)
    true = is_integer(manager_pid) and manager_pid > 0 and manager_pid != bridge_pid
    %{port: port, manager_pid: manager_pid, bridge_pid: bridge_pid}
  end

  defp finish(pending, request) do
    true = Port.command(pending.port, Jason.encode!(request) <> "\n")
    %{"phase" => "finished", "manager_pid" => manager_pid} = result = receive_line(pending.port)
    true = manager_pid == pending.manager_pid
    await_exit(pending.port)

    %{
      response: if(result["stdout"] == "", do: nil, else: Jason.decode!(result["stdout"])),
      status: result["status"],
      stdout: result["stdout"],
      stderr: result["stderr"],
      manager_pid: manager_pid,
      kernel_observation: result["kernel_observation"],
      kernel_exit_observed: result["kernel_exit_observed"],
      observed_before_crash: result["observed_before_crash"]
    }
  end

  defp receive_line(port) do
    receive do
      {^port, {:data, {:eol, line}}} -> Jason.decode!(line)
      {^port, {:data, {:noeol, _}}} -> raise "oversized local worker bridge output"
      {^port, {:exit_status, status}} -> raise "local worker bridge exited early: #{status}"
    after
      15_000 -> raise "local worker bridge timed out"
    end
  end

  defp await_exit(port) do
    receive do
      {^port, {:exit_status, 0}} -> :ok
      {^port, {:exit_status, status}} -> raise "local worker bridge failed: #{status}"
      {^port, {:data, _}} -> raise "unexpected extra local worker bridge output"
    after
      15_000 -> raise "local worker bridge did not exit"
    end
  end
end
