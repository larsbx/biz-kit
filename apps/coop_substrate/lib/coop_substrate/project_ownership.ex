defmodule CoopSubstrate.ProjectOwnership do
  @moduledoc """
  Governance-signed backfill for a legacy TaskCore project with no owner.

  This does not introduce a second project record. Existing tasks and
  grants identify legacy projects; admission preserves their history.
  Preparing emits only the missing governance declaration and operator
  grant, followed by the one accountable-owner assignment. The held batch
  is verified again against authoritative ledger state at append time.

  See docs/architecture/2026-11-02-project-ownership.md and issue #265.
  """

  alias CoopSubstrate.{Administrators, Commands, Log}
  alias TaskCore.{Admission, Projects}

  @type scope :: {String.t(), String.t(), String.t()}
  @type device :: %{key_id: String.t(), pubkey: binary()}

  @doc """
  List legacy projects that have tasks or grants but no accountable owner.
  Only a chapter governance interface should expose these records.
  """
  @spec ownerless(String.t()) :: [map()]
  def ownerless(chapter) do
    gate = Log.gate()

    for p <- Administrators.projects(gate.orchestration, chapter),
        Projects.owner(gate.orchestration, {chapter, p.tenant_id, p.project_id}) == nil,
        do: Map.put(p, :owner, nil)
  end

  @doc """
  Prepare an atomic, governance-signed ownership backfill.

  When `principal` is already declared human and has an active operator grant
  in this project, `device` may be nil. Otherwise an operator device
  `%{key_id: ..., pubkey: <<32 bytes>>}` must be supplied. `human` is a
  governance attestation, not independently established personhood.

  This is for *existing* ownerless projects only, not draft project creation.
  """
  @spec prepare_backfill(scope(), String.t(), String.t(), device() | nil) ::
          {:ok, map()} | {:error, term()}
  def prepare_backfill({chapter, _, _} = scope, principal, governance_key_id, device \\ nil) do
    with {:ok, commands} <- commands(Log.gate(), scope, principal, device),
         {:ok, signer} <- Commands.governance_signer(chapter, governance_key_id) do
      Commands.hold_batch({:project_backfill, scope, principal}, chapter, commands, signer)
    end
  end

  @doc """
  Submit one governance signature per held command. A stale grant, owner,
  principal-kind, or project change rejects the entire batch.
  """
  @spec backfill(scope(), String.t(), String.t(), [binary()]) ::
          {:ok, [CoopSubstrate.Protocol.Envelope.t()]} | {:error, term()}
  def backfill(scope, principal, held_id, signatures) do
    owner = {:project_backfill, scope, principal}

    with {:ok, [_ | _] = signed} <- Commands.signed(owner, held_id, signatures),
         commands = Enum.map(signed, &{&1.type, &1.payload}),
         do:
           Commands.submit_batch(owner, held_id, signatures,
             guard: {__MODULE__, :unchanged, [scope, principal, commands]}
           )
  end

  @doc false
  def unchanged(gate, scope, principal, expected) do
    device =
      Enum.find_value(expected, fn
        {"TaskOperatorGrantedV1", %{"key_id" => key, "pubkey" => {:bytes, pubkey}}} ->
          %{key_id: key, pubkey: pubkey}

        _ ->
          nil
      end)

    case commands(gate, scope, principal, device) do
      {:ok, ^expected} -> :ok
      _ -> {:error, :backfill_changed}
    end
  end

  defp commands(gate, {chapter, tenant, project} = scope, principal, device) do
    o = gate.orchestration

    with :ok <- valid_scope(scope),
         :ok <- valid_principal(principal),
         :ok <- existing_project(o, scope),
         :ok <- unowned(o, scope),
         :ok <- human_kind(o, chapter, principal),
         {:ok, grant} <- operator_grant(o, scope, principal, device) do
      kind =
        if Projects.kind(o, chapter, principal) == nil,
          do: [{"TaskPrincipalKindDeclaredV1", %{"principal_id" => principal, "kind" => "human"}}],
          else: []

      assignment =
        {"TaskProjectOwnerAssignedV1",
         %{
           "tenant_id" => tenant,
           "project_id" => project,
           "principal_id" => principal
         }}

      {:ok, kind ++ grant ++ [assignment]}
    end
  end

  defp valid_scope({chapter, tenant, project}) do
    if Enum.all?([chapter, tenant, project], &Admission.segment?/1),
      do: :ok,
      else: {:error, :invalid_task_scope}
  end

  defp valid_principal(p) do
    if is_binary(p) and String.trim(p) != "",
      do: :ok,
      else: {:error, :empty_task_field}
  end

  defp existing_project(o, {chapter, tenant, project}) do
    if Enum.any?(Administrators.projects(o, chapter), fn p ->
         p.tenant_id == tenant and p.project_id == project
       end),
       do: :ok,
       else: {:error, :unknown_legacy_project}
  end

  defp unowned(o, scope) do
    if Projects.owner(o, scope) == nil,
      do: :ok,
      else: {:error, :project_already_owned}
  end

  defp human_kind(o, chapter, principal) do
    case Projects.kind(o, chapter, principal) do
      nil -> :ok
      "human" -> :ok
      _ -> {:error, :principal_not_human}
    end
  end

  defp operator_grant(o, scope, principal, device) do
    existing =
      Enum.any?(o.grants, fn {_id, g} ->
        g.active and g.principal_id == principal and
          {g.chapter_id, g.tenant_id, g.project_id} == scope
      end)

    cond do
      existing ->
        if device == nil, do: {:ok, []}, else: {:error, :unnecessary_operator_device}

      not valid_device?(device) ->
        {:error, :operator_device_required}

      true ->
        {_, tenant, project} = scope

        {:ok,
         [
           {"TaskOperatorGrantedV1",
            %{
              "tenant_id" => tenant,
              "project_id" => project,
              "principal_id" => principal,
              "key_id" => device.key_id,
              "pubkey" => {:bytes, device.pubkey}
            }}
         ]}
    end
  end

  defp valid_device?(%{key_id: key, pubkey: pubkey}) do
    is_binary(key) and String.trim(key) != "" and is_binary(pubkey) and
      byte_size(pubkey) == 32
  end

  defp valid_device?(_), do: false
end
