defmodule CoopSubstrate.ExecutionFixtures do
  @moduledoc """
  A project whose tasks are taken through the lifecycle by people's devices
  (`Commands.prepare/4`, signed, submitted), for the execution and
  cancellation tests (docs/architecture/2026-10-19-execution.md,
  2026-10-19-cancel-reopen.md).
  """

  import CoopSubstrate.LogCase, only: [new_member: 1, signed_event: 3]
  import CoopSubstrate.TaskTimingFixtures

  alias CoopSubstrate.{ArtifactCustody, Commands, Crypto, Log}

  @scope {"chapter-genesis", "tenant-1", "project-1"}

  @doc "Governance, operators alice and bob, reviewer carol, tasks 1 and 2, and an SOP and input in custody."
  def world! do
    gov = new_member("governance")
    alice = new_member("operator")
    bob = new_member("operator")
    carol = new_member("reviewer")
    grants = [operator_grant(gov, alice, "alice"), operator_grant(gov, bob, "bob")]
    {:ok, _} = Log.append([declare_governance(gov) | grants])
    {:ok, _} = Log.append(reviewer_grant(gov, carol, "carol"))

    for id <- ["task-1", "task-2"],
        do: {:ok, _} = Log.append(create(alice, hd(grants), id, unscheduled()))

    # Unique per run: the artifact store outlives a test run.
    run = "#{System.unique_integer()} #{System.system_time()}"
    sop = store!("SOP #{run}")
    input = store!("Input #{run}")

    w = %{
      gov: gov,
      alice: {"alice", alice},
      alice_grant: hd(grants),
      bob: {"bob", bob},
      carol: {"carol", carol},
      sop: sop,
      input: input,
      run: run
    }

    {:ok, sop_receipt} = step(w, w.alice, {:record_custody, sop})
    {:ok, input_receipt} = step(w, w.alice, {:record_custody, input})
    Map.merge(w, %{sop_receipt: sop_receipt.event_id, input_receipt: input_receipt.event_id})
  end

  def task(id),
    do: Log.gate().orchestration.tasks[{"chapter-genesis", "tenant-1", "project-1", id}]

  # What the device does: prepare, sign the bytes, submit.
  def step(_w, {principal, member}, action) do
    with {:ok, pending} <- Commands.prepare(principal, member.signer.key_id, @scope, action) do
      Commands.submit(principal, pending.id, Crypto.sign(pending.signing_bytes, member.seed))
    end
  end

  def governance(w, id, type, payload) do
    {:ok, _} =
      Log.append(
        signed_event(
          w.gov,
          type,
          Map.merge(
            %{"tenant_id" => "tenant-1", "project_id" => "project-1", "task_id" => id},
            Map.put(payload, "expected_version", task(id).version)
          )
        )
      )
  end

  # Proposed, with a Definition of Done and readiness, the SOP acknowledged
  # by alice.
  def proposed!(w, id, predecessors) do
    {:ok, _} = step(w, w.alice, {:propose, id})

    governance(w, id, "TaskDoDDefinedV1", %{
      "criteria" => [%{"id" => "report", "description" => "Report"}]
    })

    governance(w, id, "TaskReadinessDefinedV1", %{
      "artifact_requirements" => %{"input" => {:bytes, w.input}},
      "predecessor_ids" => predecessors,
      "sop_digest" => {:bytes, w.sop}
    })

    {:ok, _} = step(w, w.alice, {:acknowledge_sop, id, w.sop_receipt})
  end

  def queued!(w, id, predecessors \\ []) do
    proposed!(w, id, predecessors)
    {:ok, _} = step(w, w.alice, {:queue, id})
  end

  def ready!(w, id) do
    queued!(w, id)
    {:ok, _} = step(w, w.alice, {:ready, id, %{"input" => w.input_receipt}})
  end

  # Evidence stored from alice's device and custody recorded, then submitted.
  def evidence(w, id, text) do
    bytes = "#{text} #{w.run}"
    digest = :crypto.hash(:sha256, bytes)
    {:ok, ^digest} = ArtifactCustody.store("alice", @scope, bytes, digest, id)
    {:ok, receipt} = step(w, w.alice, {:record_custody, digest})
    step(w, w.alice, {:submit_evidence, id, %{"report" => receipt.event_id}})
  end

  def review(w, id, decision, who \\ nil),
    do: step(w, who || w.carol, {:review, id, decision, "#{decision}: as read"})
end
