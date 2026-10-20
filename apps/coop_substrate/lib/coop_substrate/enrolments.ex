defmodule CoopSubstrate.Enrolments do
  @moduledoc """
  Self-service device enrolment (docs/architecture/2026-10-19-device-enrolment.md).

      # the person's device, signed in as `principal`; role "operator" or "reviewer"
      {:ok, challenge} = Enrolments.begin(principal, identity, scope, key_id, pubkey, label, role)
      {:ok, request}   = Enrolments.prove(principal, challenge.id, signature_over(challenge.statement))
      # request.code goes to an administrator, who holds the governance key
      {:ok, details}   = Enrolments.fetch(code)
      {:ok, pending}   = Enrolments.prepare_approval(code, governance_key_id)
      {:ok, grant}     = Enrolments.approve(code, pending.id, governance_signature)

  A request is only a request: it gives no access. Access is the grant that
  approval appends, `TaskOperatorGrantedV1` for an operator device,
  `TaskReviewerGrantedV1` for a reviewer device
  (docs/architecture/2026-10-19-execution.md), or a `RoleKeyDeclared`
  governance key naming the principal for an administrator's browser, for the
  whole chapter (docs/architecture/2026-10-19-administration.md), signed by a governance key
  declared for the chapter and admitted by the ledger as any grant is. The
  server signs nothing.

  The statement a device signs to prove it holds its key is a
  `CoopDeviceEnrolmentV1` term, not an envelope, so a signature over it can
  never pass as a signed command. The request records the identity the
  person signed in with, for the administrator to judge.

  The code is the capability for reading and approving one request: 60
  random bits, valid for three days, used once. Challenges and requests live
  in memory, in one process for the whole cluster
  (`BizKit.Cluster.Singleton`); if it moves to another node they are lost,
  and a lost request is simply asked for again.
  """

  use GenServer

  alias CoopSubstrate.{Canonical, Commands, Crypto, Log}

  @table __MODULE__
  @challenge_ttl_ms 600_000
  @request_ttl_ms 3 * 86_400_000

  # One for the cluster (`BizKit.Cluster.Singleton`): a code works on any node.
  @server BizKit.Cluster.Singleton.name(__MODULE__)

  @roles ~w(operator reviewer governance)

  @doc "The statement the device must sign: who asks, for which project, key and role."
  @spec begin(
          String.t(),
          map(),
          CoopSubstrate.Feed.View.scope(),
          String.t(),
          binary(),
          String.t(),
          String.t()
        ) ::
          {:ok, %{id: String.t(), statement: binary()}} | {:error, atom()}
  def begin(
        principal,
        identity,
        {chapter, tenant, project} = scope,
        key_id,
        pubkey,
        label,
        role \\ "operator"
      ) do
    with :ok <- check(role in @roles, :invalid_role),
         :ok <- check(is_binary(pubkey) and byte_size(pubkey) == 32, :invalid_pubkey),
         :ok <- check(key_id == key_id(pubkey), :key_id_mismatch),
         :ok <- check(is_binary(label) and String.length(label) in 1..80, :invalid_label),
         :ok <- check(not enrolled?(principal, scope, key_id, role), :already_enrolled) do
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
          "role" => role,
          "nonce" => token(16)
        })

      id = token(24)

      request = %{
        principal_id: principal,
        identity: identity,
        scope: scope,
        key_id: key_id,
        pubkey: pubkey,
        label: label,
        role: role
      }

      :ok =
        GenServer.call(
          @server,
          {:put, {{:challenge, id}, principal, {request, statement}, now() + @challenge_ttl_ms}}
        )

      {:ok, %{id: id, statement: statement}}
    end
  end

  @doc "Proof of possession: the statement signed by the key it names. Yields the request's code."
  @spec prove(String.t(), String.t(), binary()) ::
          {:ok, %{code: String.t(), expires_at: integer()}} | {:error, atom()}
  def prove(principal, id, signature),
    do: GenServer.call(@server, {:prove, principal, id, signature})

  @doc "What a person's device sees of its enrolment in a role."
  @spec status(String.t(), CoopSubstrate.Feed.View.scope(), String.t(), String.t(), integer()) ::
          :enrolled | {:pending, String.t(), integer()} | :none
  def status(principal, scope, key_id, role \\ "operator", now_ms \\ now()) do
    request = %{principal_id: principal, scope: scope, key_id: key_id, role: role}

    cond do
      enrolled?(principal, scope, key_id, role) -> :enrolled
      r = GenServer.call(@server, {:pending, request, now_ms}) -> {:pending, r.code, r.expires_at}
      true -> :none
    end
  end

  @doc "The request a code names, for the administrator to judge."
  @spec fetch(String.t(), integer()) :: {:ok, map()} | {:error, :unknown_code}
  def fetch(code, now_ms \\ now()), do: GenServer.call(@server, {:fetch, code, now_ms})

  @doc """
  Prepare the grant the request asks for (operator or reviewer), to be signed
  by the named governance key, and hold it for this code (`Commands.hold/5`).
  """
  @spec prepare_approval(String.t(), String.t(), integer()) ::
          {:ok, Commands.pending()} | {:error, term()}
  def prepare_approval(code, governance_key_id, now_ms \\ now()) do
    with {:ok, r} <- fetch(code, now_ms),
         {chapter, tenant, project} = r.scope,
         {:ok, signer} <- Commands.governance_signer(chapter, governance_key_id) do
      Commands.hold(
        {:enrolment, code},
        chapter,
        grant_type(r.role),
        grant(r, tenant, project),
        signer
      )
    end
  end

  @doc """
  Submit the governance signature; on admission the request is done. Runs in
  this process, in turn with `cancel/2` and `offboard_chapter/4`, and only
  while the request is still pending: once offboarding has cancelled it,
  an approval already prepared and signed is refused.
  """
  @spec approve(String.t(), String.t(), binary()) ::
          {:ok, CoopSubstrate.Protocol.Envelope.t()} | {:error, term()}
  def approve(code, id, signature),
    do: GenServer.call(@server, {:approve, code, id, signature})

  @doc """
  Drop the principal's pending requests for the project, or for any project
  of the chapter when `scope` is `{chapter}` (offboarding). Once it returns,
  no approval of them can be admitted.
  """
  @spec cancel(String.t(), CoopSubstrate.Feed.View.scope()) :: :ok
  def cancel(principal, scope), do: GenServer.call(@server, {:cancel, principal, scope})

  @doc """
  Submit a chapter offboarding in turn with approvals. The ledger still
  decides admission under `guard`; only a successful admission cancels the
  principal's requests. While admission is in flight, no approval can pass
  its request lookup. Used by `Offboarding.offboard_chapter/3` after its
  preliminary signature and holdings checks.
  """
  @spec offboard_chapter(String.t(), String.t(), [binary()], {module(), atom(), list()}) ::
          {:ok, [CoopSubstrate.Protocol.Envelope.t()]} | {:error, term()}
  def offboard_chapter(principal, id, signatures, guard),
    do: GenServer.call(@server, {:offboard_chapter, principal, id, signatures, guard})

  # -- internals --------------------------------------------------------------------

  @doc "The ledger type of the grant a role's enrolment appends."
  def grant_type("operator"), do: "TaskOperatorGrantedV1"
  def grant_type("reviewer"), do: "TaskReviewerGrantedV1"
  def grant_type("governance"), do: "RoleKeyDeclared"
  def grant_type(_role), do: nil

  # A governance key is the chapter's, declared for the principal holding it.
  defp grant(%{role: "governance"} = r, _tenant, _project),
    do: %{
      "role" => "governance",
      "key_id" => r.key_id,
      "pubkey" => {:bytes, r.pubkey},
      "member_id" => r.principal_id
    }

  defp grant(r, tenant, project),
    do: %{
      "tenant_id" => tenant,
      "project_id" => project,
      "principal_id" => r.principal_id,
      "key_id" => r.key_id,
      "pubkey" => {:bytes, r.pubkey},
      "device_label" => r.label
    }

  defp enrolled?(principal, {chapter, _, _}, key_id, "governance") do
    gate = Log.gate()

    Map.has_key?(gate.role_keys[{chapter, "governance"}] || %{}, key_id) and
      gate.role_key_members[{chapter, "governance", key_id}] == principal
  end

  defp enrolled?(principal, scope, key_id, role) do
    o = Log.gate().orchestration

    Enum.any?(if(role == "reviewer", do: o.dod_grants, else: o.grants), fn {_, g} ->
      g.active and g.principal_id == principal and g.key_id == key_id and
        {g.chapter_id, g.tenant_id, g.project_id} == scope
    end)
  end

  # -- in the server ------------------------------------------------------------------

  defp lookup(code, now_ms) do
    case :ets.lookup(@table, {:request, code}) do
      [{_, _, request, expires_at}] when now_ms <= expires_at ->
        {:ok, Map.merge(request, %{code: code, expires_at: expires_at})}

      _ ->
        {:error, :unknown_code}
    end
  end

  defp pending(%{principal_id: p, scope: scope, key_id: key_id, role: role}, now_ms) do
    :ets.match_object(@table, {{:request, :_}, p, :_, :_})
    |> Enum.find_value(fn {{:request, code}, _, r, expires_at} ->
      if expires_at >= now_ms and r.scope == scope and r.key_id == key_id and r.role == role,
        do: %{code: code, expires_at: expires_at}
    end)
  end

  defp store(request) do
    code = code()
    expires_at = now() + @request_ttl_ms
    true = :ets.insert_new(@table, {{:request, code}, request.principal_id, request, expires_at})
    %{code: code, expires_at: expires_at}
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
    :ets.new(@table, [:set, :protected, :named_table])
    schedule()
    {:ok, nil}
  end

  @impl true
  def handle_call({:put, row}, _from, state) do
    true = :ets.insert(@table, row)
    {:reply, :ok, state}
  end

  def handle_call({:prove, principal, id, signature}, _from, state) do
    reply =
      with {:ok, {request, statement}} <- take({:challenge, id}, principal, :unknown_challenge),
           :ok <- check(Crypto.verify(statement, signature, request.pubkey), :bad_proof),
           do: {:ok, pending(request, now()) || store(request)}

    {:reply, reply, state}
  end

  def handle_call({:pending, request, now_ms}, _from, state),
    do: {:reply, pending(request, now_ms), state}

  def handle_call({:fetch, code, now_ms}, _from, state), do: {:reply, lookup(code, now_ms), state}

  def handle_call({:approve, code, id, signature}, _from, state) do
    reply =
      with {:ok, _request} <- lookup(code, now()),
           {:ok, grant} <- Commands.submit({:enrolment, code}, id, signature) do
        :ets.delete(@table, {:request, code})
        {:ok, grant}
      end

    {:reply, reply, state}
  end

  def handle_call({:cancel, principal, scope}, _from, state) do
    cancel_pending(principal, scope)
    {:reply, :ok, state}
  end

  def handle_call({:offboard_chapter, principal, id, signatures, guard}, _from, state) do
    reply =
      with {:ok, [first | _] = appended} <-
             Commands.submit_batch({:chapter_offboarding, principal}, id, signatures,
               guard: guard
             ) do
        cancel_pending(principal, {first.chapter_id})
        {:ok, appended}
      end

    {:reply, reply, state}
  end

  defp cancel_pending(principal, scope) do
    for {key, _, %{scope: request_scope}, _} <-
          :ets.match_object(@table, {{:request, :_}, principal, :_, :_}),
        within?(request_scope, scope),
        do: :ets.delete(@table, key)
  end

  defp within?(scope, {chapter}), do: elem(scope, 0) == chapter
  defp within?(scope, scope), do: true
  defp within?(_request_scope, _scope), do: false

  @impl true
  def handle_info(:sweep, state) do
    now = now()
    :ets.select_delete(@table, [{{:_, :_, :_, :"$1"}, [{:<, :"$1", now}], [true]}])
    schedule()
    {:noreply, state}
  end

  defp schedule, do: Process.send_after(self(), :sweep, @challenge_ttl_ms)
end
