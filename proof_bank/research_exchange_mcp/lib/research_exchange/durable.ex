defmodule ResearchExchange.Durable do
  @moduledoc """
  Opt-in local transport to the durable, controlled-export bridge. The existing
  MCP calls are forwarded to one fixed repository entry point, never to a
  contributor-selected command or path. Python and its configuration are trusted
  operator inputs; the bridge owns authentication, persistence and checking.
  """
  use GenServer
  alias ResearchExchange.Evidence

  @schema "research-exchange/bridge-rpc/v1"
  @script Path.expand("../../../research_exchange_bridge/stdio.py", __DIR__)
  @max_line 131_072
  @timeout_ms 4_000
  @errors ~w(unauthorized forbidden invalid_arguments invalid_fields invalid_integer
             invalid_identifier invalid_json invalid_or_stale_binding not_found
             unknown_tool idempotency_conflict already_requested capacity conflict
             database_unavailable checker_unavailable checker_identity_changed
             checker_identity_mismatch checker_inconclusive profile_identity_mismatch
             stored_identity_mismatch artifact_changed invalid_profile proof_refused
             stale_authority stale_version invalid_configuration bridge_unavailable
             bridge_protocol_error internal_error)a
  @error_codes Map.new(@errors, fn code -> {Atom.to_string(code), code} end)

  def start_link(config), do: GenServer.start_link(__MODULE__, config)

  # Preserve the separately reviewed single-slot pilot's existing entry point.
  # Its observations and offline worker remain distinct from this bridge.
  def start_link(db, key), do: ResearchExchange.DurablePilot.start_link(db, key)

  @impl true
  def init(%{config_path: config_path, python_executable: python}) do
    Process.flag(:trap_exit, true)

    if absolute_file?(config_path) and absolute_file?(python) and File.regular?(@script) and
         System.find_executable(python) != nil do
      port =
        Port.open({:spawn_executable, python}, [
          :binary,
          :exit_status,
          {:line, @max_line},
          {:args, ["-I", "-B", @script, "--config", config_path]}
        ])

      {:ok, %{port: port, sequence: 0}}
    else
      {:stop, :invalid_configuration}
    end
  rescue
    _ -> {:stop, :bridge_unavailable}
  end

  def init(_), do: {:stop, :invalid_configuration}

  @impl true
  def handle_call({:authenticate, token}, _from, state) do
    forward(state, %{"op" => "authenticate", "token" => token})
  end

  def handle_call({:call, token, tool, arguments}, _from, state) do
    forward(state, %{
      "op" => "call",
      "token" => token,
      "tool" => tool,
      "arguments" => arguments
    })
  end

  # Worker observations, metering and privileged administration are never
  # accepted through this adapter. The controlled bridge creates its own result.
  def handle_call(_, _from, state), do: {:reply, {:error, :forbidden}, state}

  @impl true
  def handle_info({port, _}, %{port: port} = state) do
    close(port)
    {:noreply, %{state | port: nil}}
  end

  def handle_info({:EXIT, port, _}, %{port: port} = state),
    do: {:noreply, %{state | port: nil}}

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_, state), do: close(state.port)

  defp absolute_file?(path),
    do: is_binary(path) and Path.type(path) == :absolute and File.regular?(path)

  defp forward(%{port: nil} = state, _),
    do: {:reply, {:error, :bridge_unavailable}, state}

  defp forward(state, command) do
    id = state.sequence + 1
    request = Map.merge(command, %{"schema" => @schema, "id" => id})

    case encode(request) do
      {:ok, bytes} ->
        case exchange(state.port, id, bytes) do
          {:reply, result} ->
            {:reply, result, %{state | sequence: id}}

          {:failed, reason} ->
            close(state.port)
            {:reply, {:error, reason}, %{state | port: nil, sequence: id}}
        end

      :error ->
        {:reply, {:error, :invalid_arguments}, state}
    end
  end

  defp encode(request) do
    # Reject values outside the bridge's integer-only JSON subset before they
    # reach its parser. A malformed client value must not poison this session.
    bytes = Evidence.canonical(request)
    if byte_size(bytes) <= @max_line, do: {:ok, bytes}, else: :error
  rescue
    _ -> :error
  end

  defp exchange(port, id, bytes) do
    # A non-reading child must not suspend this process before the receive
    # deadline begins. Busy ports fail closed instead of waiting indefinitely.
    true = Port.command(port, bytes <> "\n", [:nosuspend])

    receive do
      {^port, {:data, {:eol, response}}} -> decode(response, id)
      {^port, {:data, {:noeol, _}}} -> {:failed, :bridge_protocol_error}
      {^port, {:exit_status, _}} -> {:failed, :bridge_unavailable}
      {:EXIT, ^port, _} -> {:failed, :bridge_unavailable}
    after
      @timeout_ms -> {:failed, :bridge_unavailable}
    end
  rescue
    _ -> {:failed, :bridge_unavailable}
  end

  defp decode(bytes, id) do
    decoders = %{
      null: nil,
      object_push: fn key, value, acc ->
        if List.keymember?(acc, key, 0), do: raise(ArgumentError, "duplicate key")
        [{key, value} | acc]
      end
    }

    {value, _, rest} = :json.decode(bytes, :ok, decoders)

    if is_map(value) and String.trim(rest) == "" and value["schema"] == @schema and
         value["id"] === id do
      response(value)
    else
      {:failed, :bridge_protocol_error}
    end
  rescue
    _ -> {:failed, :bridge_protocol_error}
  end

  defp response(%{"ok" => true, "result" => result} = value) when is_map(result) do
    if Enum.sort(Map.keys(value)) == ["id", "ok", "result", "schema"] do
      # The public MCP encoder accepts only this canonical JSON subset. Refuse
      # unsupported values before they can crash the public transport.
      Evidence.canonical(result)
      {:reply, {:ok, result}}
    else
      {:failed, :bridge_protocol_error}
    end
  end

  defp response(%{"ok" => false, "error" => code} = value) do
    with true <- Enum.sort(Map.keys(value)) == ["error", "id", "ok", "schema"],
         {:ok, reason} <- Map.fetch(@error_codes, code) do
      {:reply, {:error, reason}}
    else
      _ -> {:failed, :bridge_protocol_error}
    end
  end

  defp response(_), do: {:failed, :bridge_protocol_error}

  defp close(port) when is_port(port) do
    if Port.info(port), do: Port.close(port)
    :ok
  rescue
    _ -> :ok
  end

  defp close(_), do: :ok
end
