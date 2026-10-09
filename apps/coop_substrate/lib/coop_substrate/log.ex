defmodule CoopSubstrate.Log do
  @moduledoc """
  The append-only canonical log (phase1a_plan step 6; SUBSTRATE.md §4).

  Layout inside the event store:

    * Every event is appended — atomically, batches included — to the single
      physical stream `"ledger"`. Its order IS the global chain:
      `global_seq` == ledger stream version, assigned here, embedded in the
      hashed record.
    * Each event is additionally *linked* into its derived per-stream stream
      (`Envelope.stream_id/1`) for cheap selective reads. Links are a derived
      index, never canonical truth: per-stream integrity lives in the
      `prev_stream_hash`/`stream_seq` fields inside the hashed record, and
      missing links are repaired from the ledger on restart.

  Verify-on-append (all before anything persists; a batch is all-or-nothing):
  structural validity (type registered, payload schema, `chapter_id`,
  signer-set shape), signature-set completeness, every Ed25519 signature
  valid over the re-encoded core, canonical encodability with size/depth
  caps, and no prior log assignment. The single serialized appender
  (hand-off §1: ONE canonical log) assigns both chains.

  What is signed is what is stored is what is replayed: the store holds the
  `CoopEventCanonicalV1` bytes of the full record verbatim (bytea,
  pass-through serializer); reads re-decode strictly and re-verify.
  """

  use GenServer

  alias CoopSubstrate.Canonical
  alias CoopSubstrate.Crypto
  alias CoopSubstrate.Projections.Membership, as: Gate
  alias CoopSubstrate.Protocol.Envelope
  alias CoopSubstrate.Protocol.StreamRoot
  alias CoopSubstrate.Protocol.TypeRegistry
  alias CoopSubstrate.ULID

  @ledger "ledger"
  @page 1_000

  defmodule Head do
    @moduledoc false
    defstruct global_seq: 0, global_hash: nil, streams: %{}
  end

  # -- lifecycle ---------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(_opts) do
    {head, gate, links} = recover()
    :ok = repair_links(links)
    {:ok, %{head: head, gate: gate}}
  end

  # -- write API ---------------------------------------------------------------

  @doc """
  Append one envelope or an atomic batch. Every envelope is fully verified
  first; if any fails, nothing persists. Returns the envelopes with their
  log-assigned fields.
  """
  @spec append(Envelope.t() | [Envelope.t()], GenServer.server()) ::
          {:ok, [Envelope.t()]} | {:error, term()}
  def append(envelope_or_envelopes, server \\ __MODULE__)

  def append(%Envelope{} = envelope, server), do: append([envelope], server)

  def append(envelopes, server) when is_list(envelopes) do
    GenServer.call(server, {:append, envelopes})
  end

  @doc "Current global head: `%{global_seq: n, global_hash: <<_::256>> | nil}`."
  @spec head(GenServer.server()) :: %{global_seq: non_neg_integer(), global_hash: binary() | nil}
  def head(server \\ __MODULE__) do
    GenServer.call(server, :head)
  end

  # -- read API (straight from the store; no serialization needed) -------------

  @doc """
  All events in global order. `as_of: n` reads only events with
  `global_seq <= n` (06 P1 as-of evaluation).
  """
  @spec read_all(keyword()) :: {:ok, [Envelope.t()]} | {:error, term()}
  def read_all(opts \\ []) do
    limit = Keyword.get(opts, :as_of, :infinity)

    with {:ok, records} <- fold_ledger([], fn env, _bytes, acc -> [env | acc] end, limit) do
      {:ok, Enum.reverse(records)}
    end
  end

  @doc "One stream in stream order, via its link stream. Supports `as_of:`."
  @spec read_stream(String.t(), keyword()) :: {:ok, [Envelope.t()]} | {:error, term()}
  def read_stream(stream_id, opts \\ []) when is_binary(stream_id) do
    as_of = Keyword.get(opts, :as_of, :infinity)

    with {:ok, recorded} <- read_recorded(stream_id) do
      recorded
      |> Enum.reduce_while({:ok, []}, fn event, {:ok, acc} ->
        case decode_record(event.data) do
          {:ok, env} when as_of == :infinity or env.global_seq <= as_of ->
            {:cont, {:ok, [env | acc]}}

          {:ok, _past_as_of} ->
            {:cont, {:ok, acc}}

          {:error, reason} ->
            {:halt, {:error, {:corrupt_record, event.event_id, reason}}}
        end
      end)
      |> case do
        {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
        error -> error
      end
    end
  end

  @doc """
  Full audit of both hash-chains, from the raw stored bytes: strict canonical
  decode, every signature re-verified, `event_hash` recomputed, and both the
  global and per-stream prev-hash/sequence links checked for every event.
  Detects any mutation, deletion, or out-of-chain insert.
  """
  @spec verify_chains(keyword()) :: :ok | {:error, [term()]}
  def verify_chains(opts \\ []) do
    limit = Keyword.get(opts, :as_of, :infinity)
    initial = {%Head{}, []}

    result =
      fold_ledger_raw(initial, limit, fn position, bytes, {head, breaks} ->
        case audit_record(position, bytes, head) do
          {:ok, head} -> {head, breaks}
          {:error, break, head} -> {head, [break | breaks]}
        end
      end)

    with {:ok, {_head, breaks}} <- result do
      case breaks do
        [] -> :ok
        breaks -> {:error, Enum.reverse(breaks)}
      end
    end
  end

  # -- checkpoints (Phase 1D; hand-off §6 item 16) ------------------------------

  @doc """
  A self-contained, externalizable checkpoint: the canonical encoding of the
  current global head, signed by a `checkpoint`-role key
  (docs/phase1d_plan.md P6). Publishing the blob outside the primary
  database commits the operator to the entire history — altering append-only
  history is protected-objectives class (00 Art. VI), and this is its
  detection mechanism. Emission does not consult the registry; verification
  does.
  """
  @spec checkpoint(String.t(), String.t(), <<_::256>>) :: {:ok, binary()} | {:error, term()}
  def checkpoint(chapter_id, key_id, seed) do
    case head() do
      %{global_seq: 0} ->
        {:error, :empty_log}

      %{global_seq: seq, global_hash: hash} ->
        # 12A: V2 adds the stream-heads root, so an exported bundle can
        # prove completeness offline (docs/phase12a_plan.md). V1 blobs
        # verify forever (the §1.3 spirit applied to the blob format).
        {:ok, heads} = stream_heads(chapter_id, as_of: seq)

        {:ok, body} =
          Canonical.encode(%{
            "schema" => "CheckpointV2",
            "chapter_id" => chapter_id,
            "key_id" => key_id,
            "global_seq" => seq,
            "global_hash" => {:bytes, hash},
            "stream_heads_root" => {:bytes, StreamRoot.root(heads)}
          })

        Canonical.encode(%{
          "body" => {:bytes, body},
          "signature" => {:bytes, Crypto.sign(body, seed)}
        })
    end
  end

  @doc """
  The chapter's per-stream last-event hashes as of `as_of:` (default: the
  whole log) — the leaves the checkpoint's stream-heads root commits to
  (12A). A pure fold over the ledger.
  """
  @spec stream_heads(String.t(), keyword()) :: {:ok, %{String.t() => binary()}} | {:error, term()}
  def stream_heads(chapter_id, opts \\ []) do
    limit = Keyword.get(opts, :as_of, :infinity)
    prefix = chapter_id <> "/"

    fold_ledger(
      %{},
      fn env, _bytes, heads ->
        if String.starts_with?(env.stream_id, prefix) do
          {:ok, hash} = Envelope.event_hash(env)
          Map.put(heads, env.stream_id, hash)
        else
          heads
        end
      end,
      limit
    )
  end

  @doc """
  Independent checkpoint verification: audits both hash chains up to the
  claimed position, recomputes the head from the raw stored bytes, and
  validates the signature against the chapter's `checkpoint` keys **as of
  that position** — later revocation never invalidates a historical
  attestation, and a revoked key cannot attest any later head.
  """
  @spec verify_checkpoint(binary()) :: :ok | {:error, term()}
  def verify_checkpoint(blob) when is_binary(blob) do
    with {:ok, {body, signature}} <- unpack_checkpoint(blob),
         {:ok, cp} <- unpack_checkpoint_body(body),
         :ok <- verify_chains(as_of: cp.global_seq),
         {:ok, recomputed} <- head_at(cp.global_seq),
         {:ok, gate} <- replay(Gate, as_of: cp.global_seq) do
      declared = Map.get(gate.role_keys[{cp.chapter_id, "checkpoint"}] || %{}, cp.key_id)

      cond do
        recomputed != cp.global_hash ->
          {:error, :head_mismatch}

        declared == nil ->
          {:error, {:checkpoint_key_not_declared, cp.chapter_id, cp.key_id}}

        not Crypto.verify(body, signature, declared) ->
          {:error, :bad_signature}

        cp.stream_heads_root != nil ->
          # V2 (12A): the stream-heads root must recompute from the ledger
          # as of the attested position.
          case stream_heads(cp.chapter_id, as_of: cp.global_seq) do
            {:ok, heads} ->
              if StreamRoot.root(heads) == cp.stream_heads_root do
                :ok
              else
                {:error, :stream_root_mismatch}
              end

            {:error, _} = error ->
              error
          end

        true ->
          :ok
      end
    end
  end

  @doc "The recomputed global head hash at `global_seq`, from raw ledger bytes."
  @spec head_at(pos_integer()) :: {:ok, binary()} | {:error, term()}
  def head_at(global_seq) when is_integer(global_seq) and global_seq > 0 do
    with {:ok, {seq, hash}} <-
           fold_ledger_raw({0, nil}, global_seq, fn position, bytes, _acc ->
             {position, :crypto.hash(:sha256, bytes)}
           end) do
      if seq == global_seq, do: {:ok, hash}, else: {:error, {:unknown_global_seq, global_seq}}
    end
  end

  defp unpack_checkpoint(blob) do
    case Canonical.decode(blob) do
      {:ok, %{"body" => {:bytes, body}, "signature" => {:bytes, sig}}} -> {:ok, {body, sig}}
      {:ok, _other} -> {:error, :malformed_checkpoint}
      {:error, _} = error -> error
    end
  end

  defp unpack_checkpoint_body(body) do
    case Canonical.decode(body) do
      {:ok,
       %{
         "schema" => "CheckpointV1",
         "chapter_id" => chapter_id,
         "key_id" => key_id,
         "global_seq" => seq,
         "global_hash" => {:bytes, hash}
       }}
      when is_integer(seq) and seq > 0 ->
        {:ok,
         %{
           chapter_id: chapter_id,
           key_id: key_id,
           global_seq: seq,
           global_hash: hash,
           stream_heads_root: nil
         }}

      {:ok,
       %{
         "schema" => "CheckpointV2",
         "chapter_id" => chapter_id,
         "key_id" => key_id,
         "global_seq" => seq,
         "global_hash" => {:bytes, hash},
         "stream_heads_root" => {:bytes, root}
       }}
      when is_integer(seq) and seq > 0 ->
        {:ok,
         %{
           chapter_id: chapter_id,
           key_id: key_id,
           global_seq: seq,
           global_hash: hash,
           stream_heads_root: root
         }}

      {:ok, _other} ->
        {:error, :malformed_checkpoint}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Deterministic replay (phase1a_plan step 7): a pure fold of `projection`
  (a `CoopSubstrate.Projection`) over the log in `global_seq` order — never
  timestamp order. Supports `as_of:` like the other reads. Replaying the
  same log twice reproduces the same state exactly.
  """
  @spec replay(module(), keyword()) :: {:ok, term()} | {:error, term()}
  def replay(projection, opts \\ []) when is_atom(projection) do
    limit = Keyword.get(opts, :as_of, :infinity)

    fold_ledger(
      projection.init(),
      fn env, _bytes, state ->
        projection.handle_event(env, state)
      end,
      limit
    )
  end

  @doc """
  Signed per-stream export (08 §1, minimal for 1A): the stream's raw
  canonical records, independently verifiable via `verify_export/1` with no
  access to this store.
  """
  @spec export_stream(String.t()) :: {:ok, [binary()]} | {:error, term()}
  def export_stream(stream_id) when is_binary(stream_id) do
    with {:ok, recorded} <- read_recorded(stream_id) do
      {:ok, Enum.map(recorded, & &1.data)}
    end
  end

  @doc """
  Independent verification of an exported stream: strict decode, signatures,
  and the per-stream chain (`stream_seq` contiguous from 1,
  `prev_stream_hash` linking each record to the previous one's hash).
  """
  @spec verify_export([binary()]) :: {:ok, [Envelope.t()]} | {:error, term()}
  def verify_export(records) when is_list(records) do
    records
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, [], nil}, fn {bytes, seq}, {:ok, acc, prev} ->
      with {:ok, env} <- decode_record(bytes),
           :ok <- Envelope.verify(env),
           true <- env.stream_seq == seq or {:error, {:stream_seq_gap, seq, env.stream_seq}},
           true <-
             env.prev_stream_hash == prev_hash(prev) or {:error, {:stream_chain_break, seq}} do
        {:cont, {:ok, [env | acc], env}}
      else
        {:error, reason} -> {:halt, {:error, {:export_invalid, seq, reason}}}
      end
    end)
    |> case do
      {:ok, reversed, _prev} -> {:ok, Enum.reverse(reversed)}
      error -> error
    end
  end

  # -- GenServer ---------------------------------------------------------------

  @impl true
  def handle_call(:head, _from, %{head: head} = state) do
    {:reply, %{global_seq: head.global_seq, global_hash: head.global_hash}, state}
  end

  @impl true
  def handle_call({:append, envelopes}, _from, %{head: head, gate: gate} = state) do
    with :ok <- verify_batch(envelopes),
         :ok <- verify_validity(envelopes, gate),
         {:ok, assigned, new_head} <- assign_chains(envelopes, head),
         {:ok, event_data} <- encode_batch(assigned),
         :ok <- persist(event_data, head.global_seq) do
      link_batch(assigned, head)
      new_gate = Enum.reduce(assigned, gate, &Gate.handle_event/2)
      {:reply, {:ok, assigned}, %{state | head: new_head, gate: new_gate}}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  # -- append internals ---------------------------------------------------------

  defp verify_batch([]), do: {:error, :empty_batch}

  defp verify_batch(envelopes) do
    envelopes
    |> Enum.with_index()
    |> Enum.find_value(fn {env, index} ->
      cond do
        not match?(%Envelope{}, env) ->
          {:error, {:not_an_envelope, index}}

        Envelope.appended?(env) ->
          {:error, {:already_appended, index, env.event_id}}

        true ->
          case Envelope.verify(env) do
            :ok -> nil
            {:error, reason} -> {:error, {:reject, index, reason}}
          end
      end
    end)
    |> case do
      nil -> check_batch_event_ids(envelopes)
      error -> error
    end
  end

  defp check_batch_event_ids(envelopes) do
    ids = Enum.map(envelopes, & &1.event_id)

    if length(Enum.uniq(ids)) == length(ids) do
      :ok
    else
      {:error, :duplicate_event_id_in_batch}
    end
  end

  # Log-dependent validity (Phase 1B; 09 gated-N): each envelope is checked
  # against the gate state — the pure Membership fold of the log so far —
  # advanced through the batch in order so event N sees N-1. Rejection aborts
  # the whole batch before persistence; the advanced gate is recomputed from
  # the assigned envelopes only after the append succeeds. (The gate fold
  # never reads log-assigned fields, so folding unassigned envelopes here is
  # sound.)
  defp verify_validity(envelopes, gate) do
    envelopes
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, gate}, fn {env, index}, {:ok, gate} ->
      case TypeRegistry.validity_check(env, gate) do
        :ok -> {:cont, {:ok, Gate.handle_event(env, gate)}}
        {:error, reason} -> {:halt, {:error, {:reject, index, reason}}}
      end
    end)
    |> case do
      {:ok, _gate} -> :ok
      error -> error
    end
  end

  defp assign_chains(envelopes, %Head{} = head) do
    envelopes
    |> Enum.reduce_while({:ok, [], head}, fn env, {:ok, acc, head} ->
      {:ok, stream_id} = Envelope.stream_id(env)
      {stream_seq, stream_hash} = Map.get(head.streams, stream_id, {0, nil})

      assigned =
        Envelope.with_log_assignment(env, %{
          stream_id: stream_id,
          stream_seq: stream_seq + 1,
          global_seq: head.global_seq + 1,
          prev_stream_hash: stream_hash,
          prev_global_hash: head.global_hash
        })

      case Envelope.event_hash(assigned) do
        {:ok, hash} ->
          head = %Head{
            global_seq: head.global_seq + 1,
            global_hash: hash,
            streams: Map.put(head.streams, stream_id, {stream_seq + 1, hash})
          }

          {:cont, {:ok, [assigned | acc], head}}

        {:error, reason} ->
          {:halt, {:error, {:reject, env.event_id, reason}}}
      end
    end)
    |> case do
      {:ok, reversed, head} -> {:ok, Enum.reverse(reversed), head}
      error -> error
    end
  end

  defp encode_batch(envelopes) do
    envelopes
    |> Enum.reduce_while({:ok, []}, fn env, {:ok, acc} ->
      with {:ok, uuid} <- ULID.to_uuid(env.event_id),
           {:ok, bytes} <- Canonical.encode(Envelope.full_record_term(env)) do
        event = %EventStore.EventData{
          event_id: uuid,
          event_type: env.type,
          data: bytes,
          metadata: nil
        }

        {:cont, {:ok, [event | acc]}}
      else
        {:error, reason} -> {:halt, {:error, {:reject, env.event_id, reason}}}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      error -> error
    end
  end

  defp persist(event_data, expected_version) do
    case CoopSubstrate.EventStore.append_to_stream(@ledger, expected_version, event_data) do
      :ok -> :ok
      {:error, reason} -> {:error, {:store_append_failed, reason}}
    end
  end

  # Links are best-effort here and repaired on restart; canonical truth is
  # already durable in the ledger by the time we link.
  defp link_batch(assigned, %Head{}) do
    assigned
    |> Enum.chunk_by(& &1.stream_id)
    |> Enum.each(fn [%{stream_id: stream_id, stream_seq: first_seq} | _] = group ->
      link(stream_id, first_seq - 1, group)
    end)
  end

  defp link(stream_id, expected_version, envelopes) do
    event_ids =
      Enum.map(envelopes, fn env ->
        {:ok, uuid} = ULID.to_uuid(env.event_id)
        uuid
      end)

    case CoopSubstrate.EventStore.link_to_stream(stream_id, expected_version, event_ids) do
      :ok ->
        :ok

      {:error, reason} ->
        require Logger
        Logger.warning("stream link failed (repaired on restart): #{inspect(reason)}")
        :ok
    end
  end

  # -- recovery ----------------------------------------------------------------

  # Rebuild heads AND the validity-gate state from the ledger in one pass,
  # and collect per-stream event uuids so missing links (crash between append
  # and link) can be repaired.
  defp recover do
    initial = {%Head{}, Gate.init(), %{}}

    {:ok, {head, gate, links}} =
      fold_ledger(initial, fn env, bytes, {head, gate, links} ->
        hash = :crypto.hash(:sha256, bytes)
        {:ok, uuid} = ULID.to_uuid(env.event_id)

        head = %Head{
          global_seq: env.global_seq,
          global_hash: hash,
          streams: Map.put(head.streams, env.stream_id, {env.stream_seq, hash})
        }

        {head, Gate.handle_event(env, gate),
         Map.update(links, env.stream_id, [uuid], &[uuid | &1])}
      end)

    {head, gate,
     Map.new(links, fn {stream_id, reversed} -> {stream_id, Enum.reverse(reversed)} end)}
  end

  defp repair_links(links) do
    Enum.each(links, fn {stream_id, uuids} ->
      linked = current_link_version(stream_id)
      expected = length(uuids)

      if linked < expected do
        missing = Enum.drop(uuids, linked)
        :ok = CoopSubstrate.EventStore.link_to_stream(stream_id, linked, missing)
      end
    end)
  end

  defp current_link_version(stream_id) do
    case CoopSubstrate.EventStore.stream_info(stream_id) do
      {:ok, %{stream_version: version}} -> version
      {:error, :stream_not_found} -> 0
    end
  end

  # -- shared read internals -----------------------------------------------------

  defp fold_ledger(acc, fun, limit \\ :infinity) do
    fold_ledger_raw(acc, limit, fn position, bytes, acc ->
      case decode_record(bytes) do
        {:ok, env} ->
          fun.(env, bytes, acc)

        {:error, reason} ->
          raise "corrupt ledger record at global_seq #{position}: #{inspect(reason)}"
      end
    end)
  end

  defp fold_ledger_raw(acc, limit, fun), do: page_ledger(1, acc, limit, fun)

  defp page_ledger(start, acc, limit, fun) do
    count = if limit == :infinity, do: @page, else: min(@page, limit - start + 1)

    if count <= 0 do
      {:ok, acc}
    else
      case CoopSubstrate.EventStore.read_stream_forward(@ledger, start, count) do
        {:ok, events} ->
          acc =
            events
            |> Enum.with_index(start)
            |> Enum.reduce(acc, fn {event, position}, acc -> fun.(position, event.data, acc) end)

          if length(events) < count do
            {:ok, acc}
          else
            page_ledger(start + count, acc, limit, fun)
          end

        {:error, :stream_not_found} ->
          {:ok, acc}

        {:error, reason} ->
          {:error, {:store_read_failed, reason}}
      end
    end
  end

  defp decode_record(bytes) do
    with {:ok, term} <- Canonical.decode(bytes) do
      Envelope.from_full_record_term(term)
    end
  end

  defp prev_hash(nil), do: nil

  defp prev_hash(%Envelope{} = env) do
    {:ok, hash} = Envelope.event_hash(env)
    hash
  end

  # -- chain audit ---------------------------------------------------------------

  # Collect EVERY failed check for a record — the acceptance criterion is
  # that both chains independently detect tampering, so the audit must not
  # stop at the first break it finds. The head still advances past a broken
  # record (onto its stored hash) so later breaks are reported too.
  defp audit_record(position, bytes, %Head{} = head) do
    case decode_record(bytes) do
      {:ok, env} ->
        signature_breaks =
          case Envelope.verify(env) do
            :ok -> []
            {:error, reason} -> [{:signature, reason}]
          end

        breaks = signature_breaks ++ check_chains(position, env, head)

        # event_hash is DEFINED as SHA-256 over the stored canonical bytes,
        # so hash the bytes directly: identical for intact records, and total
        # even for tampered ones (which must be reported, never crash).
        hash = :crypto.hash(:sha256, bytes)

        new_head = %Head{
          global_seq: position,
          global_hash: hash,
          streams: Map.put(head.streams, env.stream_id, {env.stream_seq, hash})
        }

        case breaks do
          [] -> {:ok, new_head}
          breaks -> {:error, {:break, position, breaks}, new_head}
        end

      {:error, reason} ->
        new_head = %Head{head | global_seq: position, global_hash: :crypto.hash(:sha256, bytes)}
        {:error, {:break, position, [{:decode, reason}]}, new_head}
    end
  end

  defp check_chains(position, env, %Head{} = head) do
    {stream_seq, stream_hash} = Map.get(head.streams, env.stream_id, {0, nil})

    stream_id_breaks =
      case Envelope.stream_id(env) do
        {:ok, derived} when derived == env.stream_id -> []
        {:ok, derived} -> [{:stream_id_mismatch, env.stream_id, derived}]
        {:error, reason} -> [{:stream_id_underivable, reason}]
      end

    [
      {env.global_seq != position, {:global_seq_mismatch, env.global_seq}},
      {env.prev_global_hash != head.global_hash, :global_chain_break},
      {env.stream_seq != stream_seq + 1, {:stream_seq_mismatch, env.stream_seq}},
      {env.prev_stream_hash != stream_hash, :stream_chain_break}
    ]
    |> Enum.filter(&elem(&1, 0))
    |> Enum.map(&elem(&1, 1))
    |> Kernel.++(stream_id_breaks)
  end

  defp read_recorded(stream_id) do
    case CoopSubstrate.EventStore.read_stream_forward(stream_id, 0, @page) do
      {:ok, events} when length(events) < @page ->
        {:ok, events}

      {:ok, first_page} ->
        read_recorded_pages(stream_id, length(first_page) + 1, first_page)

      {:error, :stream_not_found} ->
        {:ok, []}

      {:error, reason} ->
        {:error, {:store_read_failed, reason}}
    end
  end

  defp read_recorded_pages(stream_id, start, acc) do
    case CoopSubstrate.EventStore.read_stream_forward(stream_id, start, @page) do
      {:ok, events} when length(events) < @page -> {:ok, acc ++ events}
      {:ok, events} -> read_recorded_pages(stream_id, start + @page, acc ++ events)
      {:error, reason} -> {:error, {:store_read_failed, reason}}
    end
  end
end
