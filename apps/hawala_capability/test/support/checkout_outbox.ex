defmodule HawalaCapability.TestCheckoutOutbox do
  @moduledoc "TEST-only durable business outbox. Unknown outcomes are query-only; no paid state."
  use GenServer
  alias HawalaCapability.SignedTestPort, as: Port

  def start(path, c, create),
    do:
      GenServer.start(__MODULE__, {path, c, create},
        name: {:global, {__MODULE__, Path.expand(path)}}
      )

  def submit(pid, op), do: GenServer.call(pid, {:submit, op}, 5000)
  def query(pid), do: GenServer.call(pid, :query, 5000)
  def status(pid), do: GenServer.call(pid, :status)
  def close(pid), do: GenServer.stop(pid, :normal)
  @impl true
  def init({path, c, create}) do
    with true <-
           Enum.all?(
             [:seed, :service, :grant, :attempt, :binding],
             &(is_binary(c[&1]) and byte_size(c[&1]) == 32)
           ),
         true <- is_integer(c.epoch) and c.epoch > 0 and c.epoch < 18_446_744_073_709_551_616,
         true <- (create and not File.exists?(path)) or (not create and File.regular?(path)) do
      log = make_ref()

      case :disk_log.open(
             name: log,
             file: String.to_charlist(path),
             type: :halt,
             format: :internal,
             repair: false
           ) do
        {:ok, ^log} ->
          initial = %{stage: 0, counter: 0, pending: nil, active: nil, held: false, mutations: 0}

          restored =
            if create do
              with :ok <- append(log, {:enrollment, Port.pin(c)}), do: {:ok, initial}
            else
              with {:ok, [{:enrollment, pin} | terms]} <- read(log, :start, []),
                   true <- pin == Port.pin(c),
                   do:
                     Enum.reduce_while(terms, {:ok, initial}, fn term, {:ok, s} ->
                       case fold(s, term, c) do
                         {:ok, next} -> {:cont, {:ok, next}}
                         error -> {:halt, error}
                       end
                     end)
            end

          case restored do
            {:ok, s} ->
              recover(log, c, s)

            error ->
              :disk_log.close(log)
              {:stop, {:hold_history, error}}
          end

        error ->
          {:stop, {:hold_open, error}}
      end
    else
      _ -> {:stop, :hold_enrollment}
    end
  end

  defp recover(log, c, %{active: nil} = s), do: {:ok, %{log: log, config: c, data: s}}

  defp recover(log, c, s) do
    # Persisted-before-send does not prove delivery; recovery never sends it again.
    event = {:unknown, Port.hash(s.active.raw)}

    with :ok <- append(log, event),
         {:ok, next} <- fold(s, event, c),
         do: {:ok, %{log: log, config: c, data: next}}
  end

  defp read(log, continuation, terms) do
    case :disk_log.chunk(log, continuation) do
      :eof -> {:ok, terms}
      {next, chunk} when is_list(chunk) -> read(log, next, terms ++ chunk)
      error -> {:error, error}
    end
  end

  defp append(log, event), do: with(:ok <- :disk_log.log(log, event), do: :disk_log.sync(log))

  defp fold(s, {:dispatch, kind, raw}, c) when kind in [:mutation, :query] do
    with true <- s.active == nil,
         {:ok, op} <- Port.verify_request(raw, c, s.counter + 1),
         true <-
           (kind == :query and op == 4) or
             (kind == :mutation and s.pending == nil and op == s.stage + 1 and op <= 3) do
      pending = if kind == :mutation, do: %{raw: raw, desired: op}, else: s.pending

      {:ok,
       %{
         s
         | counter: s.counter + 1,
           active: %{raw: raw, kind: kind},
           pending: pending,
           held: true,
           mutations: s.mutations + if(kind == :mutation, do: 1, else: 0)
       }}
    else
      _ -> {:error, :invalid_dispatch}
    end
  end

  defp fold(s, {:unknown, hash}, _c) do
    if s.active != nil and Port.hash(s.active.raw) == hash,
      do: {:ok, %{s | active: nil, held: true}},
      else: {:error, :wrong_unknown}
  end

  defp fold(s, {:received, hash, reply}, c) do
    with true <- s.active != nil and Port.hash(s.active.raw) == hash,
         {:ok, v} <- Port.verify_response(reply, s.active.raw, c) do
      required = if s.pending, do: s.pending.desired, else: s.stage

      if not v.held and v.stage >= required and v.stage >= s.stage,
        do: {:ok, %{s | stage: v.stage, pending: nil, active: nil, held: false}},
        else: {:ok, %{s | active: nil, held: true}}
    else
      _ -> {:error, :unverified_reply}
    end
  end

  defp fold(_, _, _), do: {:error, :invalid_history}

  defp persist(state, event) do
    with {:ok, data} <- fold(state.data, event, state.config),
         :ok <- append(state.log, event),
         do: {:ok, %{state | data: data}}
  end

  defp view(s),
    do: %{
      stage: s.stage,
      status:
        if(s.held,
          do: :held,
          else: Enum.at([:absent, :test_proposed, :test_prepared, :test_reserved], s.stage)
        ),
      paid: false,
      financial_authority: false,
      pending: s.pending != nil,
      mutations: s.mutations
    }

  @impl true
  def handle_call(:status, _from, state), do: {:reply, view(state.data), state}

  def handle_call({:submit, op}, _from, state) do
    n =
      case op do
        :create -> 1
        :prepare -> 2
        :commit_intent -> 3
        _ -> nil
      end

    cond do
      state.data.pending != nil -> {:reply, {:hold, :query_original_attempt}, state}
      n == nil or n != state.data.stage + 1 -> {:reply, {:error, :phase}, state}
      true -> dispatch(state, :mutation, n)
    end
  end

  def handle_call(:query, _from, state), do: dispatch(state, :query, 4)

  defp dispatch(state, kind, op) do
    raw = Port.request(state.config, op, state.data.counter + 1, System.system_time(:second))

    case persist(state, {:dispatch, kind, raw}) do
      {:ok, sent} ->
        result =
          case Port.exchange(state.config.socket, raw) do
            {:ok, reply} ->
              case Port.verify_response(reply, raw, state.config) do
                {:ok, _} -> {:received, Port.hash(raw), reply}
                _ -> {:unknown, Port.hash(raw)}
              end

            _ ->
              {:unknown, Port.hash(raw)}
          end

        case persist(sent, result) do
          {:ok, done} -> {:reply, view(done.data), done}
          error -> {:stop, :hold_uncertain_outbox, {:hold, error}, sent}
        end

      error ->
        # The append may be durable even if sync failed; never continue from
        # the old in-memory counter or issue a replacement request.
        {:stop, :hold_uncertain_outbox, {:hold, error}, state}
    end
  end

  @impl true
  def terminate(_reason, state), do: :disk_log.close(state.log)
end
