defmodule CoopSubstrate.ExecutionTest do
  @moduledoc """
  A task after ready (docs/architecture/2026-10-19-execution.md): an operator
  starts it, submits evidence for each criterion of its Definition of Done,
  a reviewer accepts or refuses it, and an operator completes it citing the
  accepting review. Each step is prepared by the server and signed on the
  person's device; the ledger decides whether it is allowed before anyone
  signs.
  """
  use ExUnit.Case, async: false
  use CoopSubstrate.LogCase

  import CoopSubstrate.{ExecutionFixtures, TaskTimingFixtures}

  alias CoopSubstrate.{ArtifactCustody, Log}

  @scope {"chapter-genesis", "tenant-1", "project-1"}

  setup do: world!()

  test "start, evidence, review and complete; a successor can then be ready", w do
    ready!(w, "task-1")
    queued!(w, "task-2", ["task-1"])

    assert step(w, w.alice, {:ready, "task-2", %{"input" => w.input_receipt}}) ==
             {:error, {:invalid, :incomplete_predecessors}}

    assert {:ok, %{type: "TaskStartedV1"}} = step(w, w.alice, {:start, "task-1"})
    assert %{state: "in_progress", started_by: "alice"} = task("task-1")

    assert {:ok, %{type: "TaskEvidenceSubmittedV2"} = submission} =
             evidence(w, "task-1", "The report")

    assert {:ok, %{type: "TaskDoDReviewedV1"} = accepted} = review(w, "task-1", "accept")
    assert accepted.payload["submission_event_id"] == submission.event_id
    assert hd(accepted.signers).role == "reviewer"

    assert {:ok, %{type: "TaskCompletedV1"}} =
             step(w, w.alice, {:complete, "task-1", accepted.event_id})

    assert task("task-1").state == "completed"

    assert {:ok, %{type: "TaskReadyV1"}} =
             step(w, w.alice, {:ready, "task-2", %{"input" => w.input_receipt}})
  end

  test "completing needs an accepting review of the current submission", w do
    ready!(w, "task-1")
    {:ok, _} = step(w, w.alice, {:start, "task-1"})

    assert step(w, w.alice, {:complete, "task-1", "no-review"}) ==
             {:error, {:invalid, :dod_review_mismatch}}

    {:ok, _} = evidence(w, "task-1", "A first draft")
    {:ok, refused} = review(w, "task-1", "refuse")
    assert task("task-1").dod.review.decision == "refuse"

    assert step(w, w.alice, {:complete, "task-1", refused.event_id}) ==
             {:error, {:invalid, :dod_not_accepted}}

    # Submitting again clears the refusal; the old review no longer counts.
    {:ok, _} = evidence(w, "task-1", "The final report")
    assert task("task-1").dod.review == nil

    assert step(w, w.alice, {:complete, "task-1", refused.event_id}) ==
             {:error, {:invalid, :dod_review_mismatch}}

    {:ok, accepted} = review(w, "task-1", "accept")
    assert {:ok, _} = step(w, w.bob, {:complete, "task-1", accepted.event_id})
    assert task("task-1").state == "completed"

    assert step(w, w.alice, {:start, "task-1"}) ==
             {:error, {:invalid, {:invalid_task_transition, "completed", "in_progress"}}}
  end

  test "whoever starts has acknowledged the SOP on their device; they may do so once ready", w do
    ready!(w, "task-1")

    assert step(w, w.bob, {:start, "task-1"}) ==
             {:error, {:invalid, :sop_acknowledgment_required}}

    {:ok, _} = step(w, w.bob, {:acknowledge_sop, "task-1", w.sop_receipt})
    assert {:ok, _} = step(w, w.bob, {:start, "task-1"})
    assert task("task-1").started_by == "bob"
  end

  test "starting clears evidence submitted before the work began", w do
    proposed!(w, "task-1", [])
    early = {:submit_evidence, "task-1", %{"report" => w.input_receipt}}
    assert {:ok, _} = step(w, w.alice, early)
    {:ok, _} = step(w, w.alice, {:queue, "task-1"})

    # Not while queued or ready: evidence is for a proposed or started task.
    assert step(w, w.alice, early) == {:error, {:invalid, :dod_task_not_proposed}}

    {:ok, _} = step(w, w.alice, {:ready, "task-1", %{"input" => w.input_receipt}})
    assert task("task-1").dod.submission != nil
    {:ok, _} = step(w, w.alice, {:start, "task-1"})
    assert task("task-1").dod.submission == nil
  end

  test "reviews are by a reviewer device, never of one's own submission", w do
    ready!(w, "task-1")
    {:ok, _} = step(w, w.alice, {:start, "task-1"})

    assert review(w, "task-1", "accept") == {:error, {:invalid, :dod_submission_mismatch}}

    {:ok, _} = evidence(w, "task-1", "The report")

    # Alice's operator device cannot review at all, and as a reviewer she
    # cannot review her own submission.
    assert review(w, "task-1", "accept", w.alice) == {:error, :no_reviewer_grant}

    alice_reviews = new_member("reviewer")
    {:ok, _} = Log.append(reviewer_grant(w.gov, alice_reviews, "alice"))

    assert review(w, "task-1", "accept", {"alice", alice_reviews}) ==
             {:error, {:invalid, :dod_self_review}}

    assert review(w, "task-1", "maybe") == {:error, {:invalid, :invalid_dod_review}}
    assert {:ok, _} = review(w, "task-1", "accept")
    assert review(w, "task-1", "refuse") == {:error, {:invalid, :dod_already_reviewed}}
  end

  test "evidence is stored only for a task in progress, within the person's quota", w do
    bytes = "Evidence #{w.run}"
    digest = :crypto.hash(:sha256, bytes)
    assert ArtifactCustody.store("alice", @scope, bytes, digest, "task-1") == {:error, :not_named}

    ready!(w, "task-1")
    {:ok, _} = step(w, w.alice, {:start, "task-1"})

    assert ArtifactCustody.store("carol", @scope, bytes, digest, "task-1") ==
             {:error, :no_operator_grant}

    assert {:ok, ^digest} = ArtifactCustody.store("alice", @scope, bytes, digest, "task-1")

    # 32 MiB per person and task: four files at the 8 MiB limit, not five.
    results =
      for n <- 1..5 do
        b = :binary.copy(<<n>>, ArtifactCustody.limit())
        ArtifactCustody.store("bob", @scope, b, :crypto.hash(:sha256, b), "task-1")
      end

    assert [{:ok, _}, {:ok, _}, {:ok, _}, {:ok, _}, {:error, :quota_exceeded}] = results

    # Each file is charged once: storing one again, as a retry does, still
    # succeeds with the quota spent.
    again = :binary.copy(<<1>>, ArtifactCustody.limit())

    assert {:ok, _} =
             ArtifactCustody.store("bob", @scope, again, :crypto.hash(:sha256, again), "task-1")
  end

  test "failed filesystem writes do not spend quota; missing bytes can be restored at the limit",
       w do
    ready!(w, "task-1")
    {:ok, _} = step(w, w.alice, {:start, "task-1"})
    principal = "retry-#{w.run}"
    {:ok, _} = Log.append(operator_grant(w.gov, new_member("operator"), principal))
    alias CoopSubstrate.Harness.Artifacts
    root = Application.fetch_env!(:coop_substrate, :artifact_dir)
    blocker = Path.join(root, "blocked-#{w.run}")
    File.mkdir_p!(root)
    File.write!(blocker, "not a directory")
    on_exit(fn -> File.rm(blocker) end)
    bytes = :binary.copy(<<91>>, ArtifactCustody.limit())
    digest = :crypto.hash(:sha256, bytes)

    try do
      Application.put_env(:coop_substrate, :artifact_dir, blocker)

      for _ <- 1..5 do
        assert {:error, _} = ArtifactCustody.store(principal, @scope, bytes, digest, "task-1")
      end
    after
      Application.put_env(:coop_substrate, :artifact_dir, root)
    end

    for n <- 91..94 do
      b = :binary.copy(<<n>>, ArtifactCustody.limit())

      assert {:ok, _} =
               ArtifactCustody.store(principal, @scope, b, :crypto.hash(:sha256, b), "task-1")
    end

    assert ArtifactCustody.store(
             principal,
             @scope,
             "extra",
             :crypto.hash(:sha256, "extra"),
             "task-1"
           ) ==
             {:error, :quota_exceeded}

    File.rm!(Path.join(root, Base.encode16(digest, case: :lower)))
    assert Artifacts.get(digest) == {:error, :not_found}
    assert {:ok, ^digest} = ArtifactCustody.store(principal, @scope, bytes, digest, "task-1")
    assert {:ok, ^bytes} = Artifacts.get(digest)
  end

  test "operators and reviewers read the submitted evidence; others do not", w do
    ready!(w, "task-1")
    {:ok, _} = step(w, w.alice, {:start, "task-1"})
    assert ArtifactCustody.evidence("carol", @scope, "task-1") == {:error, :no_submission}
    {:ok, submission} = evidence(w, "task-1", "The report")

    assert {:ok, %{submission_event_id: id, principal_id: "alice", evidence: %{"report" => e}}} =
             ArtifactCustody.evidence("carol", @scope, "task-1")

    assert id == submission.event_id
    assert e.digest == :crypto.hash(:sha256, "The report #{w.run}")

    assert ArtifactCustody.read("carol", @scope, e.custody_receipt_id) ==
             {:ok, "The report #{w.run}"}

    assert ArtifactCustody.read("mallory", @scope, e.custody_receipt_id) == {:error, :no_grant}
    assert ArtifactCustody.evidence("mallory", @scope, "task-1") == {:error, :no_grant}

    assert ArtifactCustody.evidence(
             "carol",
             {"chapter-genesis", "tenant-1", "project-2"},
             "task-1"
           ) ==
             {:error, :no_grant}
  end
end
