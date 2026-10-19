defmodule CoopSubstrate.Enrolments do
  @moduledoc """
  Self-service device enrolment (docs/architecture/2026-10-19-device-enrolment.md).

      # the person's device, signed in as `principal`
      {:ok, challenge} = Enrolments.begin(principal, identity, scope, key_id, pubkey, label)
      {:ok, request}   = Enrolments.prove(principal, challenge.id, signature_over(challenge.statement))
      # request.code goes to an administrator, who holds the governance key
      {:ok, details}   = Enrolments.fetch(code)
      {:ok, pending}   = Enrolments.prepare_approval(code, governance_key_id)
      {:ok, grant}     = Enrolments.approve(code, pending.id, governance_signature)

  A request is only a request: it gives no access. Access is the
  `TaskOperatorGrantedV1` that approval appends, signed by a governance key
  declared for the chapter and admitted by the ledger as any grant is. The
  server signs nothing.

  The statement a device signs to prove it holds its key is a
  `CoopDeviceEnrolmentV1` term, not an envelope, so a signature over it can
  never pass as a signed command. The request records the identity the
  person signed in with, for the administrator to judge.

  The code is the capability for reading and approving one request: 60
  random bits, valid for three days, used once. Challenges and requests live
  in this node's memory; a lost request is simply asked for again.
  """

  use GenServer

  alias CoopSubstrate.{Canonical, Commands, Crypto, Log}

  @table __MODULE__
  @challenge_ttl_ms 600_000
  @request_ttl_ms 3 * 86_400_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "The statement the device must sign: who asks, for which project and key."
  @spec begin(
          String.t(),
          map(),
          CoopSubstrate.Feed.View.scope(),
          String.t(),
          binary(),
          String.t()
        ) ::
          {:ok, %{id: String.t(), statement: binary()}} | {:error, atom()}
  def begin(principal, identity, {chapter, tenant, project} = scope, key_id, pubkey, label) do
    with :ok <- check(is_binary(pubkey) and byte_size(pubkey) == 32, :invalid_pubkey),
         :ok <- check(key_id == key_id(pubkey), :key_id_mismatch),
         :ok <- check(is_binary(label) and String.length(label) in 1..80, :invalid_label),
         :ok <- check(not enrolled?(principal, scope, key_id), :already_enrolled) do
      statement =
        Canonical.encode!(%{
          "schema" => "CoopDeviceEnrolmentV1",
          "principal_id" => principal,
          "chapter_id" => chapter,
          "tenant_id" => tenant,
          "project_id" => project,
          "key_id" => key_id,
          "pubkey" => {:bytes, pubkey},
          "label" => label,
          "nonce" => token(16)
        })

      id = token(24)

      request = %{
        principal_id: principal,
        identity: identity,
        scope: scope,
        key_id: key_id,
        pubkey: pubkey,
        label: label
      }

      :ets.insert(
        @table,
        {{:challenge, id}, principal, {request, statement}, now() + @challenge_ttl_ms}
      )

      {:ok, %{id: id, statement: statement}}
    end
  end

  @doc "Proof of possession: the statement signed by the key it names. Yields the request's code."
  @spec prove(String.t(), String.t(), binary()) ::
          {:ok, %{code: String.t(), expires_at: integer()}} | {:error, atom()}
  def prove(principal, id, signature) do
    with {:ok, {request, statement}} <- take({:challenge, id}, principal, :unknown_challenge),
         :ok <- check(Crypto.verify(statement, signature, request.pubkey), :bad_proof) do
      {:ok, pending(request) || store(request)}
    end
  end

  @doc "What a person's device sees of its enrolment."
  @spec status(String.t(), CoopSubstrate.Feed.View.scope(), String.t(), integer()) ::
          :enrolled | {:pending, String.t(), integer()} | :none
  def status(principal, scope, key_id, now_ms \\ now()) do
    request = %{principal_id: principal, scope: scope, key_id: key_id}

    cond do
      enrolled?(principal, scope, key_id) -> :enrolled
      r = pending(request, now_ms) -> {:pending, r.code, r.expires_at}
      true -> :none
    end
  end

  @doc "The request a code names, for the administrator to judge."
  @spec fetch(String.t(), integer()) :: {:ok, map()} | {:error, :unknown_code}
  def fetch(code, now_ms \\ now()) do
    case :ets.lookup(@table, {:request, code}) do
      [{_, _, request, expires_at}] when now_ms <= expires_at ->
        {:ok, Map.merge(request, %{code: code, expires_at: expires_at})}

      _ ->
        {:error, :unknown_code}
    end
  end

  @doc """
  Prepare the operator grant the request asks for, to be signed by the named
  governance key, and hold it for this code (`Commands.hold/5`).
  """
  @spec prepare_approval(String.t(), String.t(), integer()) ::
          {:ok, Commands.pending()} | {:error, term()}
  def prepare_approval(code, governance_key_id, now_ms \\ now()) do
    with {:ok, r} <- fetch(code, now_ms),
         {chapter, tenant, project} = r.scope,
         {:ok, pubkey} <- governance_key(chapter, governance_key_id) do
      Commands.hold(
        {:enrolment, code},
        chapter,
        "TaskOperatorGrantedV1",
        %{
          "tenant_id" => tenant,
          "project_id" => project,
          "principal_id" => r.principal_id,
          "key_id" => r.key_id,
          "pubkey" => {:bytes, r.pubkey}
        },
        %{role: "governance", pubkey: pubkey, key_id: governance_key_id}
      )
    end
  end

  @doc "Submit the governance signature; on admission the request is done."
  @spec approve(String.t(), String.t(), binary()) ::
          {:ok, CoopSubstrate.Protocol.Envelope.t()} | {:error, term()}
  def approve(code, id, signature) do
    with {:ok, grant} <- Commands.submit({:enrolment, code}, id, signature) do
      :ets.delete(@table, {:request, code})
      {:ok, grant}
    end
  end

  # -- internals --------------------------------------------------------------------

  defp enrolled?(principal, scope, key_id) do
    Enum.any?(Log.gate().orchestration.grants, fn {_, g} ->
      g.active and g.principal_id == principal and g.key_id == key_id and
        {g.chapter_id, g.tenant_id, g.project_id} == scope
    end)
  end

  defp pending(%{principal_id: p, scope: scope, key_id: key_id}, now_ms \\ now()) do
    :ets.match_object(@table, {{:request, :_}, p, :_, :_})
    |> Enum.find_value(fn {{:request, code}, _, r, expires_at} ->
      if expires_at >= now_ms and r.scope == scope and r.key_id == key_id,
        do: %{code: code, expires_at: expires_at}
    end)
  end

  defp store(request) do
    code = code()
    expires_at = now() + @request_ttl_ms
    true = :ets.insert_new(@table, {{:request, code}, request.principal_id, request, expires_at})
    %{code: code, expires_at: expires_at}
  end

  defp governance_key(chapter, key_id) do
    case Log.gate().role_keys[{chapter, "governance"}][key_id] do
      nil -> {:error, :unknown_governance_key}
      pubkey -> {:ok, pubkey}
    end
  end

  # Single use, and only by the principal it was issued to; anyone else's
  # attempt leaves it in place.
  defp take(key, principal, error) do
    with [{^key, ^principal, value, expires_at}] <- :ets.lookup(@table, key),
         true <- now() <= expires_at,
         [_] <- :ets.take(@table, key) do
      {:ok, value}
    else
      _ -> {:error, error}
    end
  end

  # XXXX-XXXX-XXXX: 60 bits, uppercase base32, easy to read out.
  defp code do
    :crypto.strong_rand_bytes(8)
    |> Base.encode32(padding: false)
    |> binary_part(0, 12)
    |> String.graphemes()
    |> Enum.chunk_every(4)
    |> Enum.map_join("-", &Enum.join/1)
  end

  defp key_id(<<prefix::binary-size(4), _::binary>>),
    do: "k-" <> Base.encode16(prefix, case: :lower)

  defp token(bytes), do: Base.url_encode64(:crypto.strong_rand_bytes(bytes), padding: false)
  defp now, do: System.system_time(:millisecond)

  defp check(true, _reason), do: :ok
  defp check(false, reason), do: {:error, reason}

  @impl true
  def init(_opts) do
    :ets.new(@table, [:set, :public, :named_table])
    schedule()
    {:ok, nil}
  end

  @impl true
  def handle_info(:sweep, state) do
    now = now()
    :ets.select_delete(@table, [{{:_, :_, :_, :"$1"}, [{:<, :"$1", now}], [true]}])
    schedule()
    {:noreply, state}
  end

  defp schedule, do: Process.send_after(self(), :sweep, @challenge_ttl_ms)
end
