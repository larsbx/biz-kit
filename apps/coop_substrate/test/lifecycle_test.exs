defmodule CoopSubstrate.LifecycleTest do
  @moduledoc """
  A person's lifecycle steps, prepared by the server and signed on their device
  (docs/architecture/2026-10-19-lifecycle.md): propose, acknowledge the SOP,
  queue, mark ready, and revoke a delegation they made. The ledger decides
  whether each step is allowed, before anyone signs.
  """
  use ExUnit.Case, async: false
  use CoopSubstrate.LogCase

  import CoopSubstrate.TaskTimingFixtures

  alias CoopSubstrate.{Commands, Crypto, Log}

  @scope {"chapter-genesis", "tenant-1", "project-1"}
  @key {"chapter-genesis", "tenant-1", "project-1", "task-1"}

  setup do
    gov = new_member("governance")
    op = new_member("operator")
    grant = operator_grant(gov, op, "alice")
    {:ok, _} = Log.append([declare_governance(gov), grant])
    {:ok, _} = Log.append(create(op, grant, "task-1", unscheduled()))

    sop = store!("The standard operating procedure")
    input = store!("The input the task needs")

    {:ok, [sop_receipt, input_receipt]} =
      Log.append([custody(op, grant, sop), custody(op, grant, input)])

    %{
      gov: gov,
      op: op,
      grant: grant,
      sop: sop,
      input: input,
      sop_receipt: sop_receipt.event_id,
      input_receipt: input_receipt.event_id
    }
  end

  defp task, do: Log.gate().orchestration.tasks[@key]

  # What the device does: prepare, sign the bytes, submit.
  defp step(w, action) do
    with {:ok, pending} <- Commands.prepare("alice", w.op.signer.key_id, @scope, action) do
      Commands.submit("alice", pending.id, Crypto.sign(pending.signing_bytes, w.op.seed))
    end
  end

  defp governance(w, type, payload) do
    {:ok, _} =
      Log.append(
        signed_event(
          w.gov,
          type,
          Map.merge(
            %{"tenant_id" => "tenant-1", "project_id" => "project-1", "task_id" => "task-1"},
            Map.put(payload, "expected_version", task().version)
          )
        )
      )
  end

  defp define_dod(w),
    do:
      governance(w, "TaskDoDDefinedV1", %{
        "criteria" => [%{"id" => "r", "description" => "Report"}]
      })

  defp define_readiness(w, sop \\ nil, input \\ nil),
    do:
      governance(w, "TaskReadinessDefinedV1", %{
        "artifact_requirements" => %{"input" => {:bytes, input || w.input}},
        "predecessor_ids" => [],
        "sop_digest" => {:bytes, sop || w.sop}
      })

  # A proposed task whose readiness names these digests, so they may be stored.
  defp naming(w, sop, input) do
    {:ok, _} = step(w, {:propose, "task-1"})
    define_dod(w)
    define_readiness(w, sop, input)
  end

  test "inbox to ready, every step signed on the person's device", w do
    assert task().state == "inbox"
    assert {:ok, %{type: "TaskProposedV1"}} = step(w, {:propose, "task-1"})
    assert task().state == "proposed"

    define_dod(w)
    define_readiness(w)

    assert {:ok, _} = step(w, {:acknowledge_sop, "task-1", w.sop_receipt})
    assert task().readiness.acknowledgment.principal_id == "alice"
    # The device that acknowledged, for the view to tell its own acknowledgement.
    assert task().readiness.acknowledgment.key_id == w.op.signer.key_id

    assert {:ok, _} = step(w, {:queue, "task-1"})
    assert task().state == "queued"

    assert {:ok, %{type: "TaskReadyV1"}} =
             step(w, {:ready, "task-1", %{"input" => w.input_receipt}})

    assert task().state == "ready"
  end

  test "each step is refused before signing when the ledger would refuse it", w do
    assert step(w, {:queue, "task-1"}) ==
             {:error, {:invalid, {:invalid_task_transition, "inbox", "queued"}}}

    {:ok, _} = step(w, {:propose, "task-1"})
    assert step(w, {:queue, "task-1"}) == {:error, {:invalid, :dod_not_defined}}

    define_dod(w)
    assert step(w, {:queue, "task-1"}) == {:error, {:invalid, :readiness_not_defined}}

    define_readiness(w)
    assert step(w, {:queue, "task-1"}) == {:error, {:invalid, :sop_acknowledgment_required}}

    # The SOP's receipt must be of the SOP the definition names.
    assert {:error, {:invalid, _}} = step(w, {:acknowledge_sop, "task-1", w.input_receipt})

    {:ok, _} = step(w, {:acknowledge_sop, "task-1", w.sop_receipt})
    {:ok, _} = step(w, {:queue, "task-1"})

    assert step(w, {:ready, "task-1", %{}}) == {:error, {:invalid, :invalid_readiness_receipts}}
    assert {:error, {:invalid, _}} = step(w, {:ready, "task-1", %{"input" => w.sop_receipt}})
    assert step(w, {:propose, "task-9"}) == {:error, :unknown_task}
    assert task().state == "queued"
  end

  test "a step prepared before the task changed is refused as stale", w do
    {:ok, pending} = Commands.prepare("alice", w.op.signer.key_id, @scope, {:propose, "task-1"})
    {:ok, _} = step(w, {:propose, "task-1"})

    assert {:error, {:reject, _, {:stale_task_version, 1, 2}}} =
             Commands.submit("alice", pending.id, Crypto.sign(pending.signing_bytes, w.op.seed))
  end

  test "a person stores an artifact from their device and records custody of it", w do
    # Unique per run: the artifact store outlives a test run.
    bytes = "A new SOP, uploaded #{System.unique_integer()} #{System.system_time()}"
    digest = :crypto.hash(:sha256, bytes)
    naming(w, digest, w.input)

    # Recorded only once stored.
    assert {:error, {:invalid, _}} = step(w, {:record_custody, digest})

    assert {:ok, ^digest} = CoopSubstrate.ArtifactCustody.store("alice", @scope, bytes, digest)
    assert {:ok, receipt} = step(w, {:record_custody, digest})

    assert %{digest: {:bytes, ^digest}, principal_id: "alice"} =
             Log.gate().orchestration.custody_receipts[receipt.event_id]
  end

  test "storing needs a device grant here, a digest a task names, the right hash and a bounded size",
       w do
    alias CoopSubstrate.ArtifactCustody
    bytes = "Some bytes"
    digest = :crypto.hash(:sha256, bytes)
    big = :binary.copy("x", ArtifactCustody.limit() + 1)

    unnamed = "Anything else"

    assert ArtifactCustody.store("alice", @scope, unnamed, :crypto.hash(:sha256, unnamed)) ==
             {:error, :not_named}

    naming(w, digest, :crypto.hash(:sha256, big))

    assert ArtifactCustody.store("mallory", @scope, bytes, digest) == {:error, :no_operator_grant}

    assert ArtifactCustody.store(
             "alice",
             {"chapter-genesis", "tenant-1", "project-2"},
             bytes,
             digest
           ) ==
             {:error, :no_operator_grant}

    assert ArtifactCustody.store("alice", @scope, bytes <> "!", digest) ==
             {:error, :digest_mismatch}

    assert ArtifactCustody.store("alice", @scope, big, :crypto.hash(:sha256, big)) ==
             {:error, :too_large}

    assert ArtifactCustody.store("alice", @scope, unnamed, :crypto.hash(:sha256, unnamed)) ==
             {:error, :not_named}
  end

  test "a person revokes a delegation they made, and only one in this project", w do
    {:ok, [d]} = Log.append(delegation(w.op, w.grant, new_member("operator"), "bot"))

    assert step(w, {:revoke_delegation, "no-such"}) == {:error, :unknown_delegation}
    assert {:ok, %{type: "TaskDelegationRevokedV1"}} = step(w, {:revoke_delegation, d.event_id})
    refute Log.gate().orchestration.delegations[d.event_id].active
  end
end
