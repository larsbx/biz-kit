defmodule CoopSubstrate.ArtifactCustody do
  @moduledoc """
  Scoped custody receipts on the common ledger, backed by Harness.Artifacts.

  Admission re-fetches and hashes actual bytes inside the serialized append gate.
  A receipt records verification at admission, not perpetual availability or
  correctness. Bytes stay outside the log. Readers must authorize scope before
  obtaining a replay; this internal API does not authorize public reads.
  """
  alias CoopSubstrate.{Devices, Log, Harness.Artifacts}
  alias CoopSubstrate.ArtifactCustody.Quota
  alias CoopSubstrate.Protocol.Envelope

  # What one receipt may cover: custody admission verifies at most this.
  @limit 8 * 1024 * 1024
  # Evidence a person may store for one task: two full submissions
  # (Tasks.DoD verifies at most 16 MiB of evidence per submission).
  @evidence_quota 32 * 1024 * 1024

  @doc """
  Whether the principal may store this artifact in the project, before any
  byte is read: they hold an active device grant there, and either the
  digest is one a task there names (its SOP or a required input) or it is
  evidence for `task_id`, a task there in progress
  (docs/architecture/2026-10-19-execution.md). Nothing else can be stored,
  so storage is bounded by what governance has defined and, for evidence,
  by `store/5`'s quota.
  """
  @spec may_store(String.t(), CoopSubstrate.Feed.View.scope(), <<_::256>>, String.t() | nil) ::
          :ok | {:error, :no_operator_grant | :not_named}
  def may_store(principal, scope, digest, task_id \\ nil) do
    with {:ok, _purpose} <- purpose(principal, scope, digest, task_id), do: :ok
  end

  defp purpose(principal, {chapter, tenant, project} = scope, digest, task_id) do
    cond do
      Devices.list(principal, scope) == [] ->
        {:error, :no_operator_grant}

      digest in named(scope) ->
        {:ok, :named}

      match?(
        %{state: "in_progress"},
        Log.gate().orchestration.tasks[{chapter, tenant, project, task_id}]
      ) ->
        {:ok, {:evidence, task_id}}

      true ->
        {:error, :not_named}
    end
  end

  # The digests the project's readiness definitions name.
  defp named({chapter, tenant, project}) do
    for {{^chapter, ^tenant, ^project, _}, %{readiness: %{} = r}} <-
          Log.gate().orchestration.tasks,
        {:bytes, digest} <- [r.sop_digest | Map.values(r.artifact_requirements)],
        uniq: true,
        do: digest
  end

  @doc "The largest artifact a person may store (`store/4`)."
  def limit, do: @limit

  @doc """
  Store bytes a person sent from their device, for them to record custody of
  (docs/architecture/2026-10-19-uploads.md). Only what `may_store/4` allows,
  at most `limit/0` bytes, and only if the bytes hash to `claimed` (the
  SHA-256 their device computed), so what is stored is what they chose.
  Evidence counts against the person's quota for the task, 32 MiB, each
  distinct file once; a failed write is refunded.
  Content-addressed: storing the same bytes twice is one artifact.
  """
  @spec store(String.t(), CoopSubstrate.Feed.View.scope(), binary(), <<_::256>>, String.t() | nil) ::
          {:ok, <<_::256>>} | {:error, atom()}
  def store(principal, scope, bytes, claimed, task_id \\ nil) do
    with {:ok, purpose} <- purpose(principal, scope, claimed, task_id),
         :ok <- check(byte_size(bytes) <= @limit, :too_large),
         :ok <- check(:crypto.hash(:sha256, bytes) == claimed, :digest_mismatch) do
      case purpose do
        :named ->
          Artifacts.put(bytes)

        {:evidence, task_id} ->
          Quota.store(
            {principal, scope, task_id},
            claimed,
            byte_size(bytes),
            @evidence_quota,
            fn ->
              Artifacts.put(bytes)
            end
          )
      end
    end
  end

  @doc """
  The current evidence submission on a task, for the project's operators
  and reviewers to judge: who submitted it and, per criterion, the digest
  and the custody receipt that holds it (`read/3`). Evidence stays out of
  the change feed.
  """
  @spec evidence(String.t(), CoopSubstrate.Feed.View.scope(), String.t()) ::
          {:ok, map()} | {:error, :no_grant | :unknown_task | :no_submission}
  def evidence(principal, {chapter, tenant, project} = scope, task_id) do
    o = Log.gate().orchestration

    with :ok <- participant(o, principal, scope) do
      case o.tasks[{chapter, tenant, project, task_id}] do
        nil ->
          {:error, :unknown_task}

        %{dod: %{submission: %{} = s}} ->
          receipts = s[:custody_receipts] || %{}

          {:ok,
           %{
             submission_event_id: s.event_id,
             principal_id: s.principal_id,
             evidence:
               Map.new(s.evidence, fn {criterion, {:bytes, digest}} ->
                 {criterion, %{digest: digest, custody_receipt_id: receipts[criterion]}}
               end)
           }}

        _ ->
          {:error, :no_submission}
      end
    end
  end

  @doc "A receipt's verified bytes, for the project's operators and reviewers."
  @spec read(String.t(), CoopSubstrate.Feed.View.scope(), String.t()) ::
          {:ok, binary()} | {:error, atom()}
  def read(principal, scope, receipt_id) do
    o = Log.gate().orchestration
    with :ok <- participant(o, principal, scope), do: get(o, receipt_id, scope)
  end

  # Someone with an active operator or reviewer grant in the project; a
  # suggester (an agent) is not shown evidence.
  defp participant(o, principal, scope) do
    holds? =
      Enum.any?(Map.values(o.grants) ++ Map.values(o.dod_grants), fn g ->
        g.active and g.principal_id == principal and
          {g.chapter_id, g.tenant_id, g.project_id} == scope
      end)

    check(holds?, :no_grant)
  end

  defp check(true, _reason), do: :ok
  defp check(false, reason), do: {:error, reason}

  def submit(command, server \\ CoopSubstrate.Log.server())

  def submit(%Envelope{type: "ArtifactCustodyRecordedV1"} = command, server) do
    with {:ok, [accepted]} <- Log.append(command, server),
         {:ok, hash} <- Envelope.event_hash(accepted) do
      {:ok, %{event_id: accepted.event_id, event_hash: hash, global_seq: accepted.global_seq}}
    end
  end

  def submit(_, _), do: {:error, :not_a_custody_command}

  @doc "Fetch verified bytes for a receipt in an exactly matching authorized scope."
  def get(%{custody_receipts: receipts}, id, {chapter, tenant, project}) do
    case Map.fetch(receipts, id) do
      {:ok,
       %{chapter_id: ^chapter, tenant_id: ^tenant, project_id: ^project, digest: {:bytes, hash}}} ->
        Artifacts.get_bounded(hash)

      {:ok, _} ->
        {:error, :custody_scope_mismatch}

      :error ->
        {:error, :unknown_custody_receipt}
    end
  end
end
