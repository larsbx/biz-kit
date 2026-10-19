defmodule CoopSubstrate.ArtifactCustody do
  @moduledoc """
  Scoped custody receipts on the common ledger, backed by Harness.Artifacts.

  Admission re-fetches and hashes actual bytes inside the serialized append gate.
  A receipt records verification at admission, not perpetual availability or
  correctness. Bytes stay outside the log. Readers must authorize scope before
  obtaining a replay; this internal API does not authorize public reads.
  """
  alias CoopSubstrate.{Devices, Log, Harness.Artifacts}
  alias CoopSubstrate.Protocol.Envelope

  # What one receipt may cover: custody admission verifies at most this.
  @limit 8 * 1024 * 1024

  @doc """
  Whether the principal may store this artifact in the project, before any
  byte is read: they hold an active device grant there, and the digest is
  one a task there names, its SOP or a required input. Nothing else can be
  stored, so storage is bounded by what governance has defined.
  """
  @spec may_store(String.t(), CoopSubstrate.Feed.View.scope(), <<_::256>>) ::
          :ok | {:error, :no_operator_grant | :not_named}
  def may_store(principal, scope, digest) do
    cond do
      Devices.list(principal, scope) == [] -> {:error, :no_operator_grant}
      digest not in named(scope) -> {:error, :not_named}
      true -> :ok
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
  (docs/architecture/2026-10-19-uploads.md). Only what `may_store/3` allows,
  at most `limit/0` bytes, and only if the bytes hash to `claimed` (the
  SHA-256 their device computed), so what is stored is what they chose.
  Content-addressed: storing the same bytes twice is one artifact.
  """
  @spec store(String.t(), CoopSubstrate.Feed.View.scope(), binary(), <<_::256>>) ::
          {:ok, <<_::256>>} | {:error, atom()}
  def store(principal, scope, bytes, claimed) do
    cond do
      (refused = may_store(principal, scope, claimed)) != :ok -> refused
      byte_size(bytes) > @limit -> {:error, :too_large}
      :crypto.hash(:sha256, bytes) != claimed -> {:error, :digest_mismatch}
      true -> Artifacts.put(bytes)
    end
  end

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
