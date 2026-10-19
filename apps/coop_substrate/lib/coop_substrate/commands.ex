defmodule CoopSubstrate.Commands do
  @moduledoc """
  Operator commands signed on the person's own device
  (docs/architecture/2026-10-18-decide.md).

      {:ok, pending} = Commands.prepare(principal, key_id, scope, decision)
      # the device signs pending.signing_bytes with the key named key_id
      {:ok, envelope} = Commands.submit(principal, pending.id, signature)

  `prepare/4` finds the principal's active operator grant for that key and
  project, builds the exact envelope (`Tasks.Decisions`), and checks it
  against the ledger's current state, so a decision that would be refused is
  refused before anyone signs. The envelope is held for five minutes,
  single-use and bound to the principal. `submit/3` attaches the signature,
  which must verify under the grant's key, and appends.

  The server never holds a person's key and cannot sign for them: a command
  is admitted only with the device's signature, and the ledger checks it as
  it checks every operator command.

  `hold/5` is the same mechanism for any signer: it holds an envelope for an
  owner (a principal, or `{:enrolment, code}` for a governance approval,
  `CoopSubstrate.Enrolments`) until that owner submits its signature.
  """

  use GenServer

  alias CoopSubstrate.Log
  alias CoopSubstrate.Protocol.{Envelope, TypeRegistry}
  alias CoopSubstrate.Tasks.Decisions

  @table __MODULE__
  @ttl_ms 300_000
  # Held per owner at most, oldest evicted first. Some owners need no session
  # (a governance revocation is prepared for a grant ID), so without a bound
  # anyone could fill memory with envelopes they can never sign.
  @per_owner 4

  @type pending :: %{
          id: String.t(),
          signing_bytes: binary(),
          type: String.t(),
          payload: map(),
          expires_at: integer()
        }

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @spec prepare(String.t(), String.t(), CoopSubstrate.Feed.View.scope(), Decisions.decision()) ::
          {:ok, pending()} | {:error, term()}
  def prepare(principal, key_id, {chapter, _, _} = scope, decision) do
    o = Log.gate().orchestration

    with {:ok, grant_id, grant} <- operator_grant(o, principal, key_id, scope),
         {:ok, type, payload} <-
           Decisions.command(o, scope, decision, %{
             "principal_id" => principal,
             "authorization_event_id" => grant_id,
             "lifecycle_version" => 1
           }),
         do:
           hold(principal, chapter, type, payload, %{
             role: "operator",
             pubkey: grant.pubkey,
             key_id: key_id
           })
  end

  @doc """
  Build an envelope for `signer`, check it against the ledger's current state,
  and hold it for `owner` to sign and submit.
  """
  @spec hold(term(), String.t(), String.t(), map(), Envelope.signer()) ::
          {:ok, pending()} | {:error, term()}
  def hold(owner, chapter, type, payload, signer) do
    now = System.system_time(:millisecond)

    with {:ok, env} <-
           Envelope.new(%{
             chapter_id: chapter,
             type: type,
             payload: payload,
             signers: [signer],
             timestamp_ms: now
           }),
         :ok <- invalid(TypeRegistry.validity_check(env, Log.gate())),
         {:ok, bytes} <- Envelope.signing_bytes(env) do
      id = Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)
      expires_at = now + @ttl_ms

      true =
        :ets.insert_new(@table, {id, owner, env, expires_at, System.unique_integer([:monotonic])})

      evict(owner)
      {:ok, %{id: id, signing_bytes: bytes, type: type, payload: payload, expires_at: expires_at}}
    end
  end

  @spec submit(term(), String.t(), binary(), integer()) ::
          {:ok, Envelope.t()} | {:error, term()}
  def submit(owner, id, signature, now_ms \\ System.system_time(:millisecond)) do
    # Looked up before it is taken, so nobody else can spend it; taken before
    # use, so it is used once.
    with [{^id, ^owner, _env, expires_at, _seq}] when now_ms <= expires_at <-
           :ets.lookup(@table, id),
         [{^id, _, env, _, _}] <- :ets.take(@table, id),
         {:ok, signed} <- Envelope.attach_signature(env, hd(env.signers).key_id, signature),
         {:ok, [appended]} <- Log.append(signed) do
      {:ok, appended}
    else
      {:error, _} = error -> error
      _ -> {:error, :unknown_command}
    end
  end

  @doc "The envelope held for `owner` under `id`, without spending it."
  @spec peek(term(), String.t()) :: {:ok, Envelope.t()} | {:error, :unknown_command}
  def peek(owner, id) do
    case :ets.lookup(@table, id) do
      [{^id, ^owner, env, _expires_at, _seq}] -> {:ok, env}
      _ -> {:error, :unknown_command}
    end
  end

  @doc "A governance key declared for the chapter, as the signer of a held envelope."
  @spec governance_signer(String.t(), String.t()) ::
          {:ok, Envelope.signer()} | {:error, :unknown_governance_key}
  def governance_signer(chapter, key_id) do
    case Log.gate().role_keys[{chapter, "governance"}][key_id] do
      nil -> {:error, :unknown_governance_key}
      pubkey -> {:ok, %{role: "governance", pubkey: pubkey, key_id: key_id}}
    end
  end

  defp operator_grant(o, principal, key_id, scope) do
    Enum.find_value(o.grants, {:error, :no_operator_grant}, fn {id, g} ->
      if g.active and g.principal_id == principal and g.key_id == key_id and
           {g.chapter_id, g.tenant_id, g.project_id} == scope,
         do: {:ok, id, g}
    end)
  end

  defp invalid(:ok), do: :ok
  defp invalid({:error, reason}), do: {:error, {:invalid, reason}}

  @impl true
  def init(_opts) do
    :ets.new(@table, [:set, :public, :named_table])
    schedule()
    {:ok, nil}
  end

  @impl true
  def handle_info(:sweep, state) do
    now = System.system_time(:millisecond)
    :ets.select_delete(@table, [{{:_, :_, :_, :"$1", :_}, [{:<, :"$1", now}], [true]}])
    schedule()
    {:noreply, state}
  end

  defp schedule, do: Process.send_after(self(), :sweep, @ttl_ms)

  defp evict(owner) do
    :ets.select(@table, [
      {{:"$1", :"$2", :_, :_, :"$3"}, [{:"=:=", :"$2", {:const, owner}}], [{{:"$3", :"$1"}}]}
    ])
    |> Enum.sort(:desc)
    |> Enum.drop(@per_owner)
    |> Enum.each(fn {_seq, id} -> :ets.delete(@table, id) end)
  end
end
