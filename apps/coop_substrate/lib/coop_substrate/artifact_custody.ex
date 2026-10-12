defmodule CoopSubstrate.ArtifactCustody do
  @moduledoc """
  Scoped custody receipts on the common ledger, backed by Harness.Artifacts.

  Admission re-fetches and hashes actual bytes inside the serialized append gate.
  A receipt records verification at admission, not perpetual availability or
  correctness. Bytes stay outside the log. Readers must authorize scope before
  obtaining a replay; this internal API does not authorize public reads.
  """
  alias CoopSubstrate.{Log, Harness.Artifacts}
  alias CoopSubstrate.Protocol.Envelope

  def submit(command, server \\ Log)

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
