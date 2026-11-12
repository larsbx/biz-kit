defmodule ResearchExchange.Durable do
  @moduledoc "Trusted local port for the disposable SQLite proof replay pilot."
  use GenServer
  alias ResearchExchange.Evidence

  @runtime Path.expand("../../durable/runtime.py", __DIR__)

  def start_link(db, key), do: GenServer.start_link(__MODULE__, {db, key})

  @impl true
  def init({db, key}) do
    true = byte_size(key) >= 32
    python = System.find_executable("python3") || raise "python3 required"

    port =
      Port.open({:spawn_executable, python}, [
        :binary,
        :exit_status,
        {:packet, 4},
        {:args, ["-B", @runtime, "--db", db, "port"]},
        {:env, [{~c"RESEARCH_EXCHANGE_TOKEN", false}]}
      ])

    {:ok, {port, key}}
  end

  @impl true
  def handle_call({:authenticate, token}, _from, state),
    do: exchange(%{"token" => token}, state)

  def handle_call({:call, token, tool, args}, _from, state),
    do: exchange(%{"token" => token, "tool" => tool, "args" => args}, state)

  @impl true
  def handle_info({port, {:exit_status, _}}, {port, _} = state),
    do: {:stop, :storage_unavailable, state}

  defp exchange(message, {port, key} = state) do
    true = Port.command(port, :json.encode(message))

    receive do
      {^port, {:data, data}} ->
        reply =
          case :json.decode(data) do
            %{"ok" => %{"schema" => "research-exchange/durable-evidence/v1"} = payload} ->
              {:ok, Evidence.receipt(payload, key)}

            %{"ok" => value} ->
              {:ok, value}

            %{"error" => "unknown_tool"} ->
              {:error, :unknown_tool}

            %{"error" => code} ->
              {:error, code}
          end

        {:reply, reply, state}

      {^port, {:exit_status, _}} ->
        {:stop, :storage_unavailable, {:error, :storage_unavailable}, state}
    after
      4_000 -> {:stop, :storage_unavailable, {:error, :storage_unavailable}, state}
    end
  end
end
