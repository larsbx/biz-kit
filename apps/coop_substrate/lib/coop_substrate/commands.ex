defmodule CoopSubstrate.Commands do
  @moduledoc """
  Operator commands signed on the person's own device
  (docs/architecture/2026-10-18-decide.md).

      {:ok, pending} = Commands.prepare(principal, key_id, scope, decision)
      # the device signs pending.signing_bytes with the key named key_id
      {:ok, envelope} = Commands.submit(principal, pending.id, signature)

  `prepare/4` finds the principal's active operator grant for that key and
  project (their reviewer grant, for a review), builds the exact envelope
  (`TaskCore.Decisions`, `TaskCore.Steps`), and checks it
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

  Held envelopes live in one process for the whole cluster
  (`BizKit.Cluster.Singleton`), so any node submits what any node prepared.
  """

  use GenServer

  alias CoopSubstrate.Log
  alias CoopSubstrate.Projections.Membership
  alias CoopSubstrate.Protocol.{Envelope, TypeRegistry}
  alias TaskCore.{Decisions, Steps}

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

  # One for the cluster (`BizKit.Cluster.Singleton`): any node submits what any
  # node prepared.
  @server BizKit.Cluster.Singleton.name(__MODULE__)

  @doc """
  Prepare a person's command on this device: a decision on a suggestion
  (`TaskCore.Decisions`) or a lifecycle step (`TaskCore.Steps`).
  """
  @spec prepare(
          String.t(),
          String.t(),
          CoopSubstrate.Feed.View.scope(),
          Decisions.decision() | Steps.action()
        ) ::
          {:ok, pending()} | {:error, term()}
  def prepare(principal, key_id, {chapter, _, _} = scope, command) do
    o = Log.gate().orchestration
    builder = if elem(command, 0) in [:accept, :amend, :decline], do: Decisions, else: Steps
    role = if elem(command, 0) == :review, do: "reviewer", else: "operator"

    with {:ok, grant_id, grant} <- grant(o, role, principal, key_id, scope),
         {:ok, type, payload} <-
           builder.command(o, scope, command, %{
             "principal_id" => principal,
             "authorization_event_id" => grant_id,
             "lifecycle_version" => 1
           }),
         do:
           hold(principal, chapter, type, payload, %{
             role: role,
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
    with {:ok, %{commands: [command]} = held} <-
           hold_batch(owner, chapter, [{type, payload}], signer),
         do: {:ok, held |> Map.delete(:commands) |> Map.merge(command)}
  end

  @doc """
  `hold/5` for several commands by one signer, signed together and appended
  as one atomic batch (`Log.append/1`): all of them or none. Each is checked
  against the ledger as the ones before it leave it, in order.
  """
  @spec hold_batch(term(), String.t(), [{String.t(), map()}], Envelope.signer()) ::
          {:ok, %{id: String.t(), commands: [map()], expires_at: integer()}} | {:error, term()}
  def hold_batch(owner, chapter, commands, signer) do
    now = System.system_time(:millisecond)

    with {:ok, envs} <- envelopes(chapter, commands, signer, now),
         :ok <- admissible(envs, Log.gate()) do
      id = Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)
      expires_at = now + @ttl_ms
      :ok = GenServer.call(@server, {:hold, id, owner, envs, expires_at})

      {:ok,
       %{
         id: id,
         expires_at: expires_at,
         commands:
           for env <- envs do
             {:ok, bytes} = Envelope.signing_bytes(env)
             %{signing_bytes: bytes, type: env.type, payload: env.payload}
           end
       }}
    end
  end

  @spec submit(term(), String.t(), binary(), integer()) ::
          {:ok, Envelope.t()} | {:error, term()}
  def submit(owner, id, signature, now_ms \\ System.system_time(:millisecond)) do
    with {:ok, [appended]} <- submit_batch(owner, id, [signature], now_ms: now_ms),
         do: {:ok, appended}
  end

  @doc """
  Submit one signature per held command, in order; appended all at once, or
  none. With `guard:` (`Log.append_if/3`), only if it holds at admission.
  A wrong count leaves the batch held; a bad signature spends it, as it
  spends a single command (`signed/3` checks without spending).
  """
  @spec submit_batch(term(), String.t(), [binary()], keyword()) ::
          {:ok, [Envelope.t()]} | {:error, term()}
  def submit_batch(owner, id, signatures, opts \\ []) do
    now_ms = Keyword.get_lazy(opts, :now_ms, fn -> System.system_time(:millisecond) end)

    with {:ok, held} <- peek(owner, id),
         true <- length(held) == length(signatures) or {:error, :signature_count},
         {:ok, envs} <- GenServer.call(@server, {:take, owner, id, now_ms}),
         {:ok, signed} <- attach(envs, signatures) do
      case opts[:guard] do
        nil -> Log.append(signed)
        guard -> Log.append_if(signed, guard)
      end
    end
  end

  @doc "The held batch with these signatures attached, without spending it: the count and each signature checked."
  @spec signed(term(), String.t(), [binary()]) :: {:ok, [Envelope.t()]} | {:error, term()}
  def signed(owner, id, signatures) do
    with {:ok, held} <- peek(owner, id),
         true <- length(held) == length(signatures) or {:error, :signature_count},
         do: attach(held, signatures)
  end

  defp envelopes(chapter, commands, signer, now) do
    Enum.reduce_while(commands, {:ok, []}, fn {type, payload}, {:ok, acc} ->
      case Envelope.new(%{
             chapter_id: chapter,
             type: type,
             payload: payload,
             signers: [signer],
             timestamp_ms: now
           }) do
        {:ok, env} -> {:cont, {:ok, acc ++ [env]}}
        error -> {:halt, error}
      end
    end)
  end

  # Each against the gate the ones before it leave, as `Log.append/1` checks a batch.
  defp admissible(envs, gate) do
    Enum.reduce_while(envs, gate, fn env, gate ->
      case invalid(TypeRegistry.validity_check(env, gate)) do
        :ok -> {:cont, Membership.handle_event(env, gate)}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:error, _} = error -> error
      _gate -> :ok
    end
  end

  defp attach(envs, signatures) do
    Enum.zip(envs, signatures)
    |> Enum.reduce_while({:ok, []}, fn {env, signature}, {:ok, acc} ->
      case Envelope.attach_signature(env, hd(env.signers).key_id, signature) do
        {:ok, signed} -> {:cont, {:ok, acc ++ [signed]}}
        error -> {:halt, error}
      end
    end)
  end

  @doc "The envelopes held for `owner` under `id`, in order, without spending them."
  @spec peek(term(), String.t()) :: {:ok, [Envelope.t()]} | {:error, :unknown_command}
  def peek(owner, id), do: GenServer.call(@server, {:peek, owner, id})

  @doc "A governance key declared for the chapter, as the signer of a held envelope."
  @spec governance_signer(String.t(), String.t()) ::
          {:ok, Envelope.signer()} | {:error, :unknown_governance_key}
  def governance_signer(chapter, key_id) do
    case Log.gate().role_keys[{chapter, "governance"}][key_id] do
      nil -> {:error, :unknown_governance_key}
      pubkey -> {:ok, %{role: "governance", pubkey: pubkey, key_id: key_id}}
    end
  end

  defp grant(o, role, principal, key_id, scope) do
    {grants, missing} =
      if role == "reviewer",
        do: {o.dod_grants, :no_reviewer_grant},
        else: {o.grants, :no_operator_grant}

    Enum.find_value(grants, {:error, missing}, fn {id, g} ->
      if g.active and g.principal_id == principal and g.key_id == key_id and
           {g.chapter_id, g.tenant_id, g.project_id} == scope,
         do: {:ok, id, g}
    end)
  end

  defp invalid(:ok), do: :ok
  defp invalid({:error, reason}), do: {:error, {:invalid, reason}}

  @impl true
  def init(_opts) do
    :ets.new(@table, [:set, :protected, :named_table])
    schedule()
    {:ok, nil}
  end

  @impl true
  def handle_call({:hold, id, owner, envs, expires_at}, _from, state) do
    true =
      :ets.insert_new(@table, {id, owner, envs, expires_at, System.unique_integer([:monotonic])})

    evict(owner)
    {:reply, :ok, state}
  end

  # Only by its owner, before it expires, and once.
  def handle_call({:take, owner, id, now_ms}, _from, state) do
    reply =
      case :ets.lookup(@table, id) do
        [{^id, ^owner, env, expires_at, _seq}] when now_ms <= expires_at ->
          :ets.delete(@table, id)
          {:ok, env}

        _ ->
          {:error, :unknown_command}
      end

    {:reply, reply, state}
  end

  def handle_call({:peek, owner, id}, _from, state) do
    reply =
      case :ets.lookup(@table, id) do
        [{^id, ^owner, env, _expires_at, _seq}] -> {:ok, env}
        _ -> {:error, :unknown_command}
      end

    {:reply, reply, state}
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
