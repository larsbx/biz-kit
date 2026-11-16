defmodule CoopSubstrate.Scf do
  @moduledoc """
  SCF (Système Comptable Financier) books on the canonical Log.

  Governance opens one book per chapter/entity (`ScfBookOpenedV1`, first
  exercice) and grants an entity-scoped `scf_accountant` key
  (`ScfAccountantGrantedV1`, versioned, expiring, revocable). The accountant
  signs écritures, revenue recognitions, contrepassations and clôtures.

  Admission and rebuild share ONE rulebook: a posting is admitted iff
  `ScfCore.SignedProjection.admit/4` accepts its row (built by
  `ScfReplaySource.row/1` from the chain-assigned envelope), and the gate's
  book is that fold of the admitted log. `InvoiceIssued` events of an open
  book's entity are folded too, so recognitions can cite them.

  * Postings are singleton batches, idempotent by `command_id` per book: an
    exact retry (under current authority) returns the original event without
    appending; changed content under a known id is a conflict.
  * Live admission requires a signature within 30 s of the appender clock
    and a current grant and session; historical replay uses signed time, so
    later expiry or revocation never erases admitted entries.
  * Local-first: a posting's pièce justificative must be held in this
    machine's artifact store (`Harness.Artifacts`), verified against the
    signed digest, when it is admitted. Only the digest enters the Log.
  * Book reads are signed requests authorized inside the Log mailbox; they
    are never appended.

  `scf_core` is a runtime dependency of the substrate (pure, dependency-free),
  so every release that replays a store holding SCF events can fold them.
  """
  alias CoopSubstrate.{Crypto, Log, ScfReplaySource}
  alias CoopSubstrate.Harness.Artifacts
  alias CoopSubstrate.Protocol.{Envelope, TypeRegistry}
  alias ScfCore.SignedProjection

  @clock Application.compile_env(:coop_substrate, :scf_clock, System)
  @window_ms 30_000
  @role "scf_accountant"
  @book "ScfBookOpenedV1"
  @grant "ScfAccountantGrantedV1"
  @read "ScfBookReadV1"
  @postings ~w(ScfJournalEntryPostedV1 ScfServiceRevenueRecognizedV1 ScfEntryReversedV1
               ScfFiscalYearClosedV1)
  @types [@book, @grant, @read | @postings]
  # Authority and session fields a retry may carry differently.
  @session_fields ~w(grant_version session_expires_at_ms)

  def event?(type), do: type in @types
  def postings, do: @postings
  def clock_ms, do: @clock.system_time(:millisecond)
  def init, do: %{books: %{}, grants: %{}, commands: %{}}
  def state(gate), do: Map.get(gate, :scf, init())

  # -- registration -------------------------------------------------------------

  def event_types do
    entity = %{"entity_id" => :string}

    accountant =
      Map.merge(entity, %{
        "accountant_id" => :string,
        "grant_version" => :int,
        "session_expires_at_ms" => :int
      })

    posting = &spec(@role, Map.merge(accountant, Map.put(&1, "command_id", :string)))
    dated = %{"date" => :string, "currency" => :string, "document" => :any}

    %{
      @book => spec("governance", Map.put(entity, "first_year", :int)),
      @grant =>
        spec(
          "governance",
          Map.merge(entity, %{
            "accountant_id" => :string,
            "key_id" => :string,
            "pubkey" => :pubkey,
            "active" => :bool,
            "expires_at_ms" => :int,
            "expected_version" => :int
          })
        ),
      @read => spec(@role, accountant),
      "ScfJournalEntryPostedV1" =>
        posting.(Map.merge(dated, %{"journal" => :string, "label" => :string, "lines" => :any})),
      "ScfServiceRevenueRecognizedV1" =>
        posting.(Map.merge(dated, %{"invoice" => :any, "tva_treatment" => :string})),
      "ScfEntryReversedV1" => posting.(Map.put(dated, "target", :any)),
      "ScfFiscalYearClosedV1" => posting.(%{"through" => :string, "document" => :any})
    }
  end

  def register_types!, do: TypeRegistry.register_extra!(event_types(), "SCF")

  defp spec(role, fields),
    do: %{
      required_roles: [role],
      disclosure_class: :own_data,
      stream: {:payload_field, "private-scf", "entity_id"},
      payload: %{required: fields, optional: %{}}
    }

  # -- host API -----------------------------------------------------------------

  @doc """
  Sign a posting as the host's accountant. `context`: chapter_id, entity_id,
  accountant_id, key_id, seed, grant_version, session_expires_at_ms — all
  host-derived, never form fields.
  """
  def envelope(context, type, command_id, attrs) when type in @postings,
    do:
      signed(
        type,
        context,
        Map.merge(attrs, Map.put(accountant_payload(context), "command_id", command_id))
      )

  @doc "Sign and append one posting; returns the admitted (or original) event."
  def post(context, type, command_id, attrs, server \\ Log.server()) do
    with {:ok, env} <- envelope(context, type, command_id, attrs),
         {:ok, [admitted]} <- Log.append(env, server),
         do: {:ok, admitted}
  end

  @doc "The book under current authority: ledger, postings, first and open year."
  def book(context, server \\ Log.server()) do
    with {:ok, request} <- signed(@read, context, accountant_payload(context)),
         do: Log.scf_book(request, server)
  end

  @doc "Full-record digest of an admitted event: what reversals cite."
  def digest!(%Envelope{} = env) do
    {:ok, %{ref: %{digest: digest}}} = ScfReplaySource.row(env)
    digest
  end

  defp accountant_payload(c),
    do: %{
      "entity_id" => c.entity_id,
      "accountant_id" => c.accountant_id,
      "grant_version" => c.grant_version,
      "session_expires_at_ms" => c.session_expires_at_ms
    }

  defp signed(type, c, payload) do
    with {:ok, env} <-
           Envelope.new(
             type: type,
             chapter_id: c.chapter_id,
             timestamp_ms: div(clock_ms(), 1_000) * 1_000,
             payload: payload,
             signers: [%{role: @role, key_id: c.key_id, pubkey: Crypto.pubkey_from_seed(c.seed)}]
           ),
         do: Envelope.sign(env, c.key_id, c.seed)
  end

  # -- Log hooks ----------------------------------------------------------------

  @doc false
  def read_book(%Envelope{type: @read} = env, gate) do
    now = clock_ms()

    with :ok <- Envelope.verify(env),
         false <- Envelope.appended?(env),
         :ok <- fresh(env, now),
         :ok <- accountant(env, gate, now),
         %{} = book <- state(gate).books[book_key(env)] do
      {:ok,
       %{
         entity_id: env.payload["entity_id"],
         first_year: book.first_year,
         open_year: book.projection.open_year,
         ledger: book.projection.ledger,
         postings: book.projection.postings,
         reversed: book.projection.reversed
       }}
    else
      true -> {:error, :read_request_already_appended}
      nil -> {:error, :scf_book_not_open}
      {:error, _} = error -> error
    end
  end

  def read_book(_, _), do: {:error, :invalid_scf_read}

  @doc false
  def live_check(%Envelope{type: type} = env, gate) when type in @types do
    now = clock_ms()

    with :ok <- fresh(env, now),
         {:ok, _} <- transition(env, gate, now),
         do: document_held(env)
  end

  def live_check(_, _), do: :ok

  # Live admission only, after authority and the SCF rules: the pièce's bytes
  # must be in this machine's artifact store and hash to the signed digest.
  # Replay never reads files, so later local erasure cannot break history.
  defp document_held(%Envelope{
         payload: %{"document" => %{"sha256" => {:bytes, <<_::256>> = digest}}}
       }) do
    case Artifacts.verify(digest) do
      {:ok, _size} -> :ok
      {:error, reason} -> {:error, {:scf_document_unavailable, reason}}
    end
  end

  defp document_held(_), do: :ok

  @doc false
  def fold!(env, gate) do
    with :ok <- Envelope.verify(env),
         {:ok, next} <- transition(env, gate, env.timestamp_ms) do
      next
    else
      error -> raise "inconsistent SCF history: #{inspect(error)}"
    end
  end

  @doc false
  # Folds an admitted InvoiceIssued into its entity's open book, if any.
  def observe(
        %Envelope{type: "InvoiceIssued", chapter_id: ch, payload: %{"entity_id" => entity}} = env,
        gate
      ) do
    s = state(gate)

    case s.books[{ch, entity}] do
      nil ->
        gate

      book ->
        case admit(book, env) do
          {:ok, book} -> Map.put(gate, :scf, put_in(s.books[{ch, entity}], book))
          error -> raise "inconsistent SCF invoice history: #{inspect(error)}"
        end
    end
  end

  def observe(_, gate), do: gate

  @doc false
  # Before the generic duplicate path: exact retries return the original.
  def duplicate(envelopes, gate) do
    if Enum.any?(envelopes, &event?(&1.type)) do
      case envelopes do
        [%Envelope{type: @read}] -> {:error, :scf_reads_are_not_log_events}
        [%Envelope{type: type} = env] when type in @postings -> command_duplicate(env, gate)
        [_] -> :new
        _ -> {:error, :scf_requires_singleton_batch}
      end
    else
      :new
    end
  end

  # A new command id takes the ordinary admission path (and its refusals); a
  # known one is a retry, which must still carry current authority.
  defp command_duplicate(env, gate) do
    case state(gate).commands[command_key(env)] do
      nil ->
        :new

      original ->
        with :ok <- accountant(env, gate, clock_ms()) do
          if original.type == env.type and
               Map.drop(original.payload, @session_fields) ==
                 Map.drop(env.payload, @session_fields),
             do: {:ok, [original]},
             else: {:error, :scf_idempotency_conflict}
        end
    end
  end

  # -- transitions --------------------------------------------------------------

  defp transition(%Envelope{type: @book} = env, gate, _now) do
    s = state(gate)
    year = env.payload["first_year"]

    with :ok <- governance(env, gate),
         :ok <- ids(env),
         true <- (is_integer(year) and year in 1..9998) || {:error, :invalid_first_year},
         false <- Map.has_key?(s.books, book_key(env)) do
      book = %{first_year: year, projection: SignedProjection.new(year)}
      {:ok, put_in(s.books[book_key(env)], book)}
    else
      true -> {:error, :scf_book_already_open}
      error -> error
    end
  end

  defp transition(%Envelope{type: @grant} = env, gate, now) do
    p = env.payload
    s = state(gate)
    key = grant_key(env)

    with :ok <- governance(env, gate),
         :ok <- ids(env),
         true <- Map.has_key?(s.books, book_key(env)) || {:error, :scf_book_not_open},
         :ok <- expected(s.grants[key], p["expected_version"]),
         true <-
           (id?(p["key_id"]) and is_integer(p["expires_at_ms"]) and
              (not p["active"] or p["expires_at_ms"] > now)) || {:error, :invalid_scf_grant},
         {:bytes, <<_::256>> = pubkey} <- p["pubkey"] do
      row = %{
        key_id: p["key_id"],
        pubkey: pubkey,
        active: p["active"],
        expires_at_ms: p["expires_at_ms"],
        version: p["expected_version"] + 1
      }

      {:ok, put_in(s.grants[key], row)}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_scf_grant}
    end
  end

  defp transition(%Envelope{type: type} = env, gate, now) when type in @postings do
    s = state(gate)

    with :ok <- accountant(env, gate, now),
         true <- id?(env.payload["command_id"]) || {:error, :invalid_command_id},
         false <- Map.has_key?(s.commands, command_key(env)),
         %{} = book <- s.books[book_key(env)] || {:error, :scf_book_not_open},
         {:ok, book} <- admit(book, env) do
      {:ok,
       s
       |> put_in([:books, book_key(env)], book)
       |> put_in([:commands, command_key(env)], env)}
    else
      true -> {:error, :scf_command_replay}
      error -> error
    end
  end

  defp transition(_, _, _), do: {:error, :scf_reads_are_not_log_events}

  defp admit(book, env) do
    {ch, entity} = {env.chapter_id, env.payload["entity_id"]}
    profile = %{chapter: ch, entity: entity, first_year: book.first_year}

    with {:ok, row} <- ScfReplaySource.row(env),
         {:ok, projection} <-
           SignedProjection.admit(book.projection, profile, row.ref, row.payload),
         do: {:ok, %{book | projection: projection}}
  end

  # -- authority ----------------------------------------------------------------

  defp fresh(env, now) do
    if abs(now - env.timestamp_ms) <= @window_ms,
      do: :ok,
      else: {:error, :stale_scf_admission_time}
  end

  defp governance(env, gate) do
    case env.signers do
      [%{role: "governance", key_id: id, pubkey: pubkey}] ->
        if get_in(gate, [:role_keys, {env.chapter_id, "governance"}, id]) == pubkey,
          do: :ok,
          else: {:error, :scf_governance_required}

      _ ->
        {:error, :scf_governance_required}
    end
  end

  defp accountant(env, gate, now) do
    p = env.payload

    case {state(gate).grants[grant_key(env)], env.signers} do
      {%{active: true, key_id: key, pubkey: pub, version: version, expires_at_ms: expires},
       [%{role: @role, key_id: key, pubkey: pub}]} ->
        if p["grant_version"] == version and expires > now and
             is_integer(p["session_expires_at_ms"]) and p["session_expires_at_ms"] > now,
           do: :ok,
           else: {:error, :scf_authority_expired_or_replaced}

      _ ->
        {:error, :scf_forbidden}
    end
  end

  defp ids(env) do
    if id?(env.chapter_id) and id?(env.payload["entity_id"]) and
         (env.type != @grant or id?(env.payload["accountant_id"])),
       do: :ok,
       else: {:error, :invalid_scf_scope}
  end

  defp book_key(env), do: {env.chapter_id, env.payload["entity_id"]}

  defp grant_key(env),
    do: {env.chapter_id, env.payload["entity_id"], env.payload["accountant_id"]}

  defp command_key(env), do: {env.chapter_id, env.payload["entity_id"], env.payload["command_id"]}
  defp expected(nil, 0), do: :ok
  defp expected(%{version: v}, v), do: :ok
  defp expected(_, _), do: {:error, :stale_authority_version}
  defp id?(v), do: is_binary(v) and Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9._-]{0,127}\z/, v)
end
