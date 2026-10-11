defmodule CoopSubstrate.Tasks.DoDCommandsTest do
  use CoopSubstrate.LogCase, async: false
  alias CoopSubstrate.{Canonical, Log, Tasks}
  alias CoopSubstrate.Projections.Tasks, as: Projection
  alias CoopSubstrate.Tasks.DoD

  @scope %{"tenant_id" => "tenant-1", "project_id" => "project-1"}
  @subject Map.put(@scope, "task_id", "task-1")
  @key {"chapter-genesis", "tenant-1", "project-1", "task-1"}
  @criteria [%{"id" => "report", "description" => "Report supplied"}]

  setup do
    gov = new_member("governance")
    worker = new_member("operator")
    reviewer = new_member("reviewer")

    {:ok, _} =
      Log.append(
        signed_event(gov, "RoleKeyDeclared", %{
          "role" => "governance",
          "key_id" => gov.signer.key_id,
          "pubkey" => {:bytes, gov.signer.pubkey}
        })
      )

    grant =
      signed_event(
        gov,
        "TaskOperatorGrantedV1",
        Map.merge(@scope, %{
          "principal_id" => "worker",
          "key_id" => worker.signer.key_id,
          "pubkey" => {:bytes, worker.signer.pubkey}
        })
      )

    reviewer_grant =
      signed_event(
        gov,
        "TaskReviewerGrantedV1",
        Map.merge(@scope, %{
          "principal_id" => "reviewer",
          "key_id" => reviewer.signer.key_id,
          "pubkey" => {:bytes, reviewer.signer.pubkey}
        })
      )

    baseline =
      signed_event(
        gov,
        "TaskBaselineRecordedV1",
        Map.merge(@subject, %{
          "legacy_row_id" => "legacy-1",
          "title" => "Inspection",
          "definition_of_done" => "Report supplied",
          "definition_ref" => {:bytes, Canonical.hash!(@criteria)},
          "source_digest" => {:bytes, Canonical.hash!("legacy")}
        })
      )

    {:ok, _} = Log.append([grant, reviewer_grant, baseline])

    proposal =
      signed_event(
        worker,
        "TaskProposedV1",
        Map.merge(@subject, %{
          "principal_id" => "worker",
          "authorization_event_id" => grant.event_id,
          "expected_version" => 1,
          "lifecycle_version" => 1
        })
      )

    {:ok, _} = Tasks.propose(proposal)
    %{gov: gov, worker: worker, reviewer: reviewer, grant: grant, reviewer_grant: reviewer_grant}
  end

  defp definition(ctx, version \\ 2, criteria \\ @criteria) do
    signed_event(
      ctx.gov,
      "TaskDoDDefinedV1",
      Map.merge(@subject, %{
        "expected_version" => version,
        "criteria" => criteria
      })
    )
  end

  defp submission(ctx, definition, version \\ 3, changes \\ %{}) do
    signed_event(
      ctx.worker,
      "TaskEvidenceSubmittedV1",
      Map.merge(
        Map.merge(@subject, %{
          "principal_id" => "worker",
          "authorization_event_id" => ctx.grant.event_id,
          "expected_version" => version,
          "definition_event_id" => definition.event_id,
          "evidence" => %{"report" => {:bytes, Canonical.hash!("artifact bytes")}}
        }),
        changes
      )
    )
  end

  defp review(ctx, definition, submission, version \\ 4, changes \\ %{}) do
    signed_event(
      ctx.reviewer,
      "TaskDoDReviewedV1",
      Map.merge(
        Map.merge(@subject, %{
          "principal_id" => "reviewer",
          "authorization_event_id" => ctx.reviewer_grant.event_id,
          "expected_version" => version,
          "definition_event_id" => definition.event_id,
          "submission_event_id" => submission.event_id,
          "decision" => "accept",
          "reason" => "Evidence inspected"
        }),
        changes
      )
    )
  end

  defp reject(command, reason) do
    head = Log.head()
    state = Log.replay(Projection)
    assert {:error, {:reject, 0, ^reason}} = Log.append(command)
    assert Log.head() == head
    assert Log.replay(Projection) == state
  end

  test "authoritative gate and standalone task replay fold all DoD events identically", ctx do
    d = definition(ctx)
    s = submission(ctx, d)
    r = review(ctx, d, s)
    {:ok, _} = Log.append([d, s, r])
    {:ok, tasks} = Log.replay(Projection)
    {:ok, gate} = Log.replay(CoopSubstrate.Projections.Membership)
    assert gate.orchestration == tasks
    assert gate.orchestration.dod_grants[ctx.reviewer_grant.event_id].active
    assert gate.orchestration.tasks[@key].version == 5
    assert gate.orchestration.tasks[@key].dod.review.decision == "accept"

    revoke =
      signed_event(
        ctx.gov,
        "TaskReviewerRevokedV1",
        Map.put(@scope, "authorization_event_id", ctx.reviewer_grant.event_id)
      )

    {:ok, _} = Log.append(revoke)
    restart_log()
    {:ok, tasks} = Log.replay(Projection)
    {:ok, gate} = Log.replay(CoopSubstrate.Projections.Membership)
    assert gate.orchestration == tasks
    refute gate.orchestration.dod_grants[ctx.reviewer_grant.event_id].active
  end

  test "definition, evidence and independent review are durable and replayable", ctx do
    d = definition(ctx)
    s = submission(ctx, d)
    r = review(ctx, d, s)
    for command <- [d, s, r], do: assert({:ok, _} = DoD.submit(command))
    {:ok, state} = Log.replay(Projection)
    task = state.tasks[@key]
    assert task.version == 5
    assert task.state == "proposed"
    assert task.dod.definition_ref == {:bytes, Canonical.hash!(@criteria)}
    assert task.dod.review.decision == "accept"
    assert task.dod.review.submission_event_id == s.event_id
    restart_log()
    assert Log.replay(Projection) == {:ok, state}
    head = Log.head()
    for command <- [d, s, r], do: assert({:ok, _} = DoD.submit(command))
    assert Log.head() == head
    assert :ok = Log.verify_chains()

    assert {:ok, [card]} =
             CoopSubstrate.Buzz.Tasks.cards(state, {"chapter-genesis", "tenant-1", "project-1"})

    assert card["dod"]["review"]["decision"] == "accept"
    assert card["state"] == "proposed"
  end

  test "criteria and evidence fail closed on direct append", ctx do
    reject(definition(ctx, 2, []), :invalid_dod_criteria)
    d = definition(ctx)
    {:ok, _} = DoD.submit(d)
    reject(submission(ctx, d, 3, %{"evidence" => %{}}), :invalid_dod_evidence)
    reject(submission(ctx, d, 3, %{"definition_event_id" => "other"}), :dod_revision_mismatch)
    reject(submission(ctx, d, 2), {:stale_task_version, 2, 3})
  end

  test "an operator grant does not confer reviewer authority", ctx do
    d = definition(ctx)
    s = submission(ctx, d)
    {:ok, _} = Log.append([d, s])

    reject(
      review(ctx, d, s, 4, %{"authorization_event_id" => ctx.grant.event_id}),
      :unknown_reviewer_grant
    )

    reject(review(ctx, d, s, 4, %{"decision" => "thumbs_up"}), :invalid_dod_review)
    reject(review(ctx, d, s, 4, %{"reason" => " "}), :invalid_dod_review)
  end

  test "self-review is refused even with a separate reviewer key", ctx do
    grant =
      signed_event(
        ctx.gov,
        "TaskReviewerGrantedV1",
        Map.merge(@scope, %{
          "principal_id" => "worker",
          "key_id" => ctx.reviewer.signer.key_id,
          "pubkey" => {:bytes, ctx.reviewer.signer.pubkey}
        })
      )

    {:ok, _} = Log.append(grant)
    d = definition(ctx)
    s = submission(ctx, d)
    {:ok, _} = Log.append([d, s])

    reject(
      review(ctx, d, s, 4, %{
        "principal_id" => "worker",
        "authorization_event_id" => grant.event_id
      }),
      :dod_self_review
    )
  end

  test "revocation and scope are rechecked by the append gate", ctx do
    d = definition(ctx)
    s = submission(ctx, d)
    {:ok, _} = Log.append([d, s])
    reject(review(ctx, d, s, 4, %{"project_id" => "other"}), :task_grant_scope_mismatch)

    revoke =
      signed_event(
        ctx.gov,
        "TaskReviewerRevokedV1",
        Map.put(@scope, "authorization_event_id", ctx.reviewer_grant.event_id)
      )

    head = Log.head()
    assert {:error, {:reject, 1, :task_grant_revoked}} = Log.append([revoke, review(ctx, d, s)])
    assert Log.head() == head
    {:ok, _} = Log.append(revoke)
    reject(review(ctx, d, s), :task_grant_revoked)
  end

  test "revised definitions and replacement evidence invalidate previous acceptance", ctx do
    d = definition(ctx)
    s = submission(ctx, d)
    {:ok, _} = Log.append([d, s, review(ctx, d, s)])
    s2 = submission(ctx, d, 5)
    {:ok, _} = DoD.submit(s2)
    reject(review(ctx, d, s, 6), :dod_submission_mismatch)
    {:ok, state} = Log.replay(Projection)
    assert state.tasks[@key].dod.review == nil
    d2 = definition(ctx, 6, [%{"id" => "photo", "description" => "Photograph"}])
    {:ok, _} = DoD.submit(d2)
    reject(review(ctx, d, s2, 7), :dod_revision_mismatch)
    {:ok, state} = Log.replay(Projection)
    assert state.tasks[@key].dod.submission == nil
    assert state.tasks[@key].dod.review == nil
    assert state.tasks[@key].state == "proposed"
  end

  test "key reuse cannot evade separation by changing the principal", ctx do
    reviewer = %{ctx.worker | signer: %{ctx.worker.signer | role: "reviewer"}}

    grant =
      signed_event(
        ctx.gov,
        "TaskReviewerGrantedV1",
        Map.merge(@scope, %{
          "principal_id" => "different-principal",
          "key_id" => reviewer.signer.key_id,
          "pubkey" => {:bytes, reviewer.signer.pubkey}
        })
      )

    {:ok, _} = Log.append(grant)
    d = definition(ctx)
    s = submission(ctx, d)
    {:ok, _} = Log.append([d, s])
    changed = %{ctx | reviewer: reviewer, reviewer_grant: grant}
    reject(review(changed, d, s, 4, %{"principal_id" => "different-principal"}), :dod_self_review)
  end

  test "a decision cannot be overwritten and a refused submission can be replaced", ctx do
    d = definition(ctx)
    s = submission(ctx, d)
    refused = review(ctx, d, s, 4, %{"decision" => "refuse", "reason" => "Report incomplete"})
    {:ok, _} = Log.append([d, s, refused])
    reject(review(ctx, d, s, 5), :dod_already_reviewed)
    s2 = submission(ctx, d, 5)
    {:ok, _} = Log.append([s2, review(ctx, d, s2, 6)])
    {:ok, state} = Log.replay(Projection)
    assert state.tasks[@key].dod.review.decision == "accept"
    assert state.tasks[@key].version == 7
    assert state.tasks[@key].state == "proposed"
  end

  test "evidence needs a definition and current operator authority", ctx do
    reject(submission(ctx, %{event_id: "missing-definition"}, 2), :dod_not_defined)
    d = definition(ctx)
    {:ok, _} = DoD.submit(d)

    revoked =
      signed_event(
        ctx.gov,
        "TaskOperatorRevokedV1",
        Map.put(@scope, "authorization_event_id", ctx.grant.event_id)
      )

    {:ok, _} = Log.append(revoked)
    reject(submission(ctx, d), :task_grant_revoked)
  end

  test "concurrent definitions cannot both consume the same task version", ctx do
    results =
      [definition(ctx), definition(ctx)]
      |> Enum.map(fn command -> Task.async(fn -> DoD.submit(command) end) end)
      |> Enum.map(&Task.await/1)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert {:error, {:reject, 0, {:stale_task_version, 2, 3}}} in results
  end

  test "retry ID conflicts are rejected rather than overwriting definitions", ctx do
    d = definition(ctx)
    {:ok, receipt} = DoD.submit(d)

    {:ok, changed} =
      CoopSubstrate.Protocol.Envelope.sign(
        %{
          d
          | payload:
              Map.put(d.payload, "criteria", [%{"id" => "other", "description" => "Other"}])
        },
        ctx.gov.signer.key_id,
        ctx.gov.seed
      )

    reject(changed, :task_command_id_conflict)
    assert DoD.submit(d) == {:ok, receipt}
  end
end
