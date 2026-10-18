defmodule CoopSubstrate.Feed do
  @moduledoc """
  The change feed: one project's view, kept current from the ledger
  (docs/architecture/2026-10-18-change-feed.md; spec/change_feed.qnt).

  A subscriber process opens a session at a cursor (a `global_seq`; 0 for
  everything), gets one frame bringing its client from the cursor to the head,
  then a frame per ledger notification that changes the project:

      {:ok, reader} = Feed.authorize(request, signature)
      {:ok, session, frame} = Feed.open(scope, cursor, reader)
      # on {:coop_ledger, envelopes}:  {frame | nil | :revoked, session} = Feed.advance(session, envelopes)
      # on a heartbeat timer:          {frame | nil | :revoked, session} = Feed.tick(session)

  A frame is `%{seq: n, changes: [View.change()]}`: applying its changes to
  the client's view as of the previous frame gives the view as of `n`, which
  is the cursor to resume from.

  Delivery, as the model checks it: `open/2` registers before it reads the
  store, so an append is read, notified, or both, never neither. `advance/2`
  drops envelopes at or below the cursor and backfills from the store when
  notifications skip ahead. A notification lost with the appender is caught up
  by the next notification or `tick/1`.

  Access (`Feed.Access`): a session opened for a reader serves only the
  reader's scope, and ends with `:revoked` at the first event after which the
  reader's grant is no longer active. That event's batch sends no frame. A
  session opened without a reader is for trusted in-process callers only.

  One session per process: notifications go to the process, not the session.
  """

  alias CoopSubstrate.Feed.{Access, Nonces, View}
  alias CoopSubstrate.Log
  alias CoopSubstrate.Projections.Membership, as: Gate

  @registry CoopSubstrate.Feed.Registry

  @enforce_keys [:scope, :seq, :gate, :view]
  defstruct @enforce_keys ++ [reader: nil]

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

  @doc """
  Check a signed read request against the ledger's grants as of now, and
  spend its nonce. The nonce is spent only by a request that passes, so a
  forged request cannot burn a genuine one.
  """
  @spec authorize(Access.request(), binary()) :: {:ok, Access.t()} | {:error, atom()}
  def authorize(request, signature) do
    now = System.system_time(:millisecond)

    with {:ok, reader} <- Access.authorize(Log.gate().orchestration, request, signature, now),
         :ok <- Nonces.claim(request.nonce, request.timestamp_ms),
         do: {:ok, reader}
  end

  @doc "The reader for a principal authenticated outside the ledger, as of now."
  @spec authorize_principal(String.t(), View.scope()) :: {:ok, Access.t()} | {:error, :no_grant}
  def authorize_principal(principal_id, scope),
    do: Access.for_principal(Log.gate().orchestration, principal_id, scope)

  @spec open(View.scope(), integer(), Access.t() | nil) :: {:ok, t(), frame()} | {:error, term()}
  def open(scope, cursor, reader \\ nil)

  def open(scope, cursor, reader) when is_integer(cursor) and cursor >= 0 do
    {:ok, _} = Registry.register(@registry, :ledger, nil)

    with true <- reader == nil or reader.scope == scope or {:error, :scope_mismatch},
         true <- cursor <= Log.head().global_seq or {:error, :cursor_ahead},
         {:ok, gate} <- Log.replay(Gate, as_of: cursor),
         {:ok, {frame, session}} <-
           catch_up(%__MODULE__{
             scope: scope,
             seq: cursor,
             gate: gate,
             view: select(gate, scope),
             reader: reader
           }),
         true <- (frame != :revoked and live?(session)) or {:error, :grant_revoked} do
      {:ok, session, frame || %{seq: session.seq, changes: []}}
    else
      error -> close_with(error)
    end
  end

  def open(_scope, _cursor, _reader), do: {:error, :invalid_cursor}

  @spec advance(t(), [CoopSubstrate.Protocol.Envelope.t()]) :: {frame() | nil | :revoked, t()}
  def advance(%__MODULE__{seq: seq} = session, envelopes) do
    case Enum.drop_while(envelopes, &(&1.global_seq <= seq)) do
      [] -> {nil, session}
      [%{global_seq: next} | _] = fresh when next == seq + 1 -> fold(session, fresh)
      _gap -> catch_up!(session)
    end
  end

  @spec tick(t()) :: {frame() | nil | :revoked, t()}
  def tick(%__MODULE__{seq: seq} = session) do
    if Log.head().global_seq > seq, do: catch_up!(session), else: {nil, session}
  end

  @spec seq(t()) :: non_neg_integer()
  def seq(%__MODULE__{seq: seq}), do: seq

  @doc "Stop notifications to the calling process. Exiting does the same."
  @spec close(t() | nil) :: :ok
  def close(_session), do: Registry.unregister(@registry, :ledger)

  # -- internals --------------------------------------------------------------------

  defp close_with(error) do
    close(nil)
    error
  end

  defp live?(%__MODULE__{reader: nil}), do: true

  defp live?(%__MODULE__{reader: reader, gate: gate}),
    do: Access.live?(gate.orchestration, reader)

  defp catch_up(%__MODULE__{seq: seq} = session) do
    with {:ok, envelopes} <- Log.read_all(from: seq + 1), do: {:ok, fold(session, envelopes)}
  end

  defp catch_up!(session) do
    {:ok, result} = catch_up(session)
    result
  end

  # The cursor moves with every event, in scope or not; a frame only when the
  # view changed, and none once the reader's grant is gone.
  defp fold(session, []), do: {nil, session}

  defp fold(%__MODULE__{view: old} = session, envelopes) do
    gate = Enum.reduce(envelopes, session.gate, &Gate.handle_event/2)
    view = select(gate, session.scope)
    seq = List.last(envelopes).global_seq
    session = %{session | gate: gate, view: view, seq: seq}

    cond do
      not live?(session) -> {:revoked, session}
      view == old -> {nil, session}
      true -> {%{seq: seq, changes: View.diff(old, view)}, session}
    end
  end

  defp select(gate, scope), do: View.select(gate.orchestration, scope)
end
