defmodule CoopSubstrate.Feed do
  @moduledoc """
  The change feed: one project's view, kept current from the ledger
  (docs/architecture/2026-10-18-change-feed.md; spec/change_feed.qnt).

  A subscriber process opens a session at a cursor (a `global_seq`; 0 for
  everything), gets one frame bringing its client from the cursor to the head,
  then a frame per ledger notification that changes the project:

      {:ok, session, frame} = Feed.open(scope, cursor)
      # on {:coop_ledger, envelopes}:  {frame | nil, session} = Feed.advance(session, envelopes)
      # on a heartbeat timer:          {frame | nil, session} = Feed.tick(session)

  A frame is `%{seq: n, changes: [View.change()]}`: applying its changes to
  the client's view as of the previous frame gives the view as of `n`, which
  is the cursor to resume from.

  Delivery, as the model checks it: `open/2` registers before it reads the
  store, so an append is read, notified, or both, never neither. `advance/2`
  drops envelopes at or below the cursor and backfills from the store when
  notifications skip ahead. A notification lost with the appender is caught up
  by the next notification or `tick/1`.

  One session per process: notifications go to the process, not the session.
  The feed decides nothing about who may read a project. The transport that
  serves it must authorise the scope first.
  """

  alias CoopSubstrate.Feed.View
  alias CoopSubstrate.Log
  alias CoopSubstrate.Projections.Membership, as: Gate

  @registry CoopSubstrate.Feed.Registry

  @enforce_keys [:scope, :seq, :gate, :view]
  defstruct @enforce_keys

  @opaque t :: %__MODULE__{}
  @type frame :: %{seq: non_neg_integer(), changes: [View.change()]}

  @doc "The registry `Log` notifies; started before it."
  def child_spec(_opts), do: Registry.child_spec(keys: :duplicate, name: @registry)

  @doc "Called by `Log` after each persisted append, in ledger order."
  @spec publish([CoopSubstrate.Protocol.Envelope.t()]) :: :ok
  def publish(envelopes) do
    Registry.dispatch(@registry, :ledger, fn entries ->
      for {pid, _} <- entries, do: send(pid, {:coop_ledger, envelopes})
    end)
  end

  @spec open(View.scope(), integer()) :: {:ok, t(), frame()} | {:error, term()}
  def open(scope, cursor) when is_integer(cursor) and cursor >= 0 do
    {:ok, _} = Registry.register(@registry, :ledger, nil)

    with true <- cursor <= Log.head().global_seq or {:error, :cursor_ahead},
         {:ok, gate} <- Log.replay(Gate, as_of: cursor),
         session = %__MODULE__{scope: scope, seq: cursor, gate: gate, view: select(gate, scope)},
         {:ok, {frame, session}} <- catch_up(session) do
      {:ok, session, frame || %{seq: session.seq, changes: []}}
    else
      error ->
        close(nil)
        error
    end
  end

  def open(_scope, _cursor), do: {:error, :invalid_cursor}

  @spec advance(t(), [CoopSubstrate.Protocol.Envelope.t()]) :: {frame() | nil, t()}
  def advance(%__MODULE__{seq: seq} = session, envelopes) do
    case Enum.drop_while(envelopes, &(&1.global_seq <= seq)) do
      [] -> {nil, session}
      [%{global_seq: next} | _] = fresh when next == seq + 1 -> fold(session, fresh)
      _gap -> catch_up!(session)
    end
  end

  @spec tick(t()) :: {frame() | nil, t()}
  def tick(%__MODULE__{seq: seq} = session) do
    if Log.head().global_seq > seq, do: catch_up!(session), else: {nil, session}
  end

  @spec seq(t()) :: non_neg_integer()
  def seq(%__MODULE__{seq: seq}), do: seq

  @doc "Stop notifications to the calling process. Exiting does the same."
  @spec close(t() | nil) :: :ok
  def close(_session), do: Registry.unregister(@registry, :ledger)

  # -- internals --------------------------------------------------------------------

  defp catch_up(%__MODULE__{seq: seq} = session) do
    with {:ok, envelopes} <- Log.read_all(from: seq + 1), do: {:ok, fold(session, envelopes)}
  end

  defp catch_up!(session) do
    {:ok, result} = catch_up(session)
    result
  end

  # The cursor moves with every event, in scope or not; a frame only when the
  # view changed.
  defp fold(session, []), do: {nil, session}

  defp fold(%__MODULE__{view: old} = session, envelopes) do
    gate = Enum.reduce(envelopes, session.gate, &Gate.handle_event/2)
    view = select(gate, session.scope)
    seq = List.last(envelopes).global_seq
    session = %{session | gate: gate, view: view, seq: seq}

    case View.diff(old, view) do
      [] -> {nil, session}
      changes -> {%{seq: seq, changes: changes}, session}
    end
  end

  defp select(gate, scope), do: View.select(gate.orchestration, scope)
end
