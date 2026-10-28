defmodule HawalaCapability.TestJournal do
  @moduledoc """
  TEST-ONLY, single-BEAM-owner append journal. No financial authority.
  One synced disk_log term contains the local state AND permanent receipt.
  Unclean/corrupt logs require HOLD; automatic repair/truncation is disabled.
  This is not a production store or a cross-VM/host locking protocol.
  """
  use GenServer
  @profile :hawala_cross_authority_test_v1

  def start(path, role, initial, create) do
    GenServer.start(__MODULE__, {path, role, initial, create},
      name: {:global, {__MODULE__, Path.expand(path)}}
    )
  end

  def snapshot(pid), do: GenServer.call(pid, :snapshot)

  def apply(pid, id, body, version, next),
    do: GenServer.call(pid, {:apply, id, body, version, next})

  def close(pid) do
    monitor = Process.monitor(pid)

    try do
      GenServer.stop(pid, :normal)
    catch
      :exit, _ -> :ok
    end

    receive do
      {:DOWN, ^monitor, :process, ^pid, _reason} -> :ok
    after
      5_000 -> exit(:hold_close_timeout)
    end
  end

  @impl true
  def init({path, role, initial, create}) do
    cond do
      create and File.exists?(path) -> {:stop, :already_enrolled}
      not create and not File.regular?(path) -> {:stop, :hold_missing_store}
      true -> open(path, role, initial, create)
    end
  end

  defp open(path, role, initial, create) do
    log = make_ref()

    options = [
      name: log,
      file: String.to_charlist(path),
      type: :halt,
      format: :internal,
      repair: false
    ]

    case :disk_log.open(options) do
      {:ok, ^log} ->
        result =
          if create do
            with :ok <- append(log, {:enrollment, @profile, role, initial}),
                 do: {:ok, %{log: log, local: initial, version: 0, receipts: %{}}}
          else
            restore(log, role, initial)
          end

        case result do
          {:ok, state} ->
            {:ok, state}

          error ->
            :disk_log.close(log)
            {:stop, {:hold_store, error}}
        end

      error ->
        {:stop, {:hold_open, error}}
    end
  end

  defp restore(log, role, initial) do
    with {:ok, terms} <- read(log, :start, []),
         [{:enrollment, @profile, ^role, ^initial} | commands] <- terms do
      Enum.reduce_while(
        commands,
        {:ok, %{log: log, local: initial, version: 0, receipts: %{}}},
        fn
          {:command, id, body, version, local}, {:ok, state} ->
            valid =
              valid_id?(id) and is_binary(body) and
                version == state.version + 1 and not Map.has_key?(state.receipts, id) and
                valid_local?(local, initial)

            if valid do
              receipt = %{version: version, local: local}

              {:cont,
               {:ok,
                %{
                  state
                  | version: version,
                    local: local,
                    receipts: Map.put(state.receipts, id, {body, receipt})
                }}}
            else
              {:halt, {:error, :invalid_history}}
            end

          _, _ ->
            {:halt, {:error, :invalid_history}}
        end
      )
    else
      _ -> {:error, :invalid_enrollment}
    end
  end

  defp read(log, continuation, terms) do
    case :disk_log.chunk(log, continuation) do
      :eof -> {:ok, terms}
      {next, chunk} when is_list(chunk) -> read(log, next, terms ++ chunk)
      error -> {:error, error}
    end
  end

  defp valid_local?(local, initial) when is_map(local) do
    Map.keys(local) == Map.keys(initial) and
      Enum.all?(local, fn {key, value} ->
        max = if key in ~w(voteL voteR decision wire localL localR), do: 2, else: 1
        is_integer(value) and value >= 0 and value <= max
      end)
  end

  defp valid_local?(_, _), do: false

  defp valid_id?(id) when is_binary(id),
    do: byte_size(id) in 1..128 and Enum.all?(:binary.bin_to_list(id), &(&1 < 128))

  defp valid_id?(_), do: false

  defp append(log, term) do
    with :ok <- :disk_log.log(log, term), do: :disk_log.sync(log)
  end

  @impl true
  def handle_call(:snapshot, _from, state), do: {:reply, {state.version, state.local}, state}

  def handle_call({:apply, id, body, version, next}, _from, state) do
    cond do
      not valid_id?(id) ->
        {:reply, {:error, :invalid_id}, state}

      Map.has_key?(state.receipts, id) ->
        case state.receipts[id] do
          {^body, receipt} -> {:reply, {:ok, Map.put(receipt, :replayed, true)}, state}
          _ -> {:reply, {:error, :payload_conflict}, state}
        end

      version != state.version ->
        {:reply, {:error, :stale_version}, state}

      not valid_local?(next, state.local) ->
        {:reply, {:error, :invalid_state}, state}

      true ->
        receipt = %{version: version + 1, local: next}

        case append(state.log, {:command, id, body, receipt.version, next}) do
          :ok ->
            new = %{
              state
              | version: receipt.version,
                local: next,
                receipts: Map.put(state.receipts, id, {body, receipt})
            }

            {:reply, {:ok, Map.put(receipt, :replayed, false)}, new}

          error ->
            # The append might have reached storage. No reply may claim success,
            # and this process must not accept a replacement attempt.
            {:stop, :uncertain_append, {:error, {:hold, error}}, state}
        end
    end
  end

  @impl true
  def terminate(_reason, state), do: :disk_log.close(state.log)
end
