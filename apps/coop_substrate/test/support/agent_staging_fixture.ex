defmodule CoopSubstrate.AgentStagingFixture do
  @moduledoc "Signed ledger fixture shared by staging-only agent acceptance."
  import ExUnit.Assertions
  import ExUnit.Callbacks, only: [on_exit: 1]
  import CoopSubstrate.LogCase
  alias CoopSubstrate.{Log, Tasks}
  alias CoopSubstrate.Harness.Artifacts
  alias CoopSubstrate.Projections.Tasks, as: Projection

  @scope %{"tenant_id" => "tenant-1", "project_id" => "project-1"}
  @subject Map.put(@scope, "task_id", "task-1")
  @task_key {"chapter-genesis", "tenant-1", "project-1", "task-1"}
  @criteria [%{"id" => "review", "description" => "Independent output review"}]

  def prepare do
    previous = Application.get_env(:coop_substrate, :artifact_dir)
    directory = Path.join(System.tmp_dir!(), "run-intent-" <> CoopSubstrate.ULID.generate())
    Application.put_env(:coop_substrate, :artifact_dir, directory)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:coop_substrate, :artifact_dir, previous),
        else: Application.delete_env(:coop_substrate, :artifact_dir)

      File.rm_rf!(directory)
    end)

    gov = new_member("governance")
    op = new_member("operator")
    agent = new_member("suggester")

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
          "principal_id" => "operator-1",
          "key_id" => op.signer.key_id,
          "pubkey" => {:bytes, op.signer.pubkey}
        })
      )

    suggester =
      signed_event(
        gov,
        "TaskSuggesterGrantedV1",
        Map.merge(@scope, %{
          "principal_id" => "agent-1",
          "key_id" => agent.signer.key_id,
          "pubkey" => {:bytes, agent.signer.pubkey}
        })
      )

    baseline =
      signed_event(
        gov,
        "TaskBaselineRecordedV1",
        Map.merge(@subject, %{
          "legacy_row_id" => "legacy-1",
          "title" => "Agent review test",
          "definition_of_done" => "Independent review",
          "source_digest" => {:bytes, :crypto.hash(:sha256, "source")},
          "definition_ref" => {:bytes, :crypto.hash(:sha256, "definition")}
        })
      )

    {:ok, _} = Log.append([grant, suggester, baseline])

    actor = %{
      "principal_id" => "operator-1",
      "authorization_event_id" => grant.event_id,
      "lifecycle_version" => 1
    }

    proposer =
      signed_event(
        op,
        "TaskProposedV1",
        Map.merge(Map.merge(@subject, actor), %{"expected_version" => 1})
      )

    assert {:ok, _} = Tasks.propose(proposer)

    {:ok, _} =
      Log.append(
        signed_event(
          gov,
          "TaskDoDDefinedV1",
          Map.merge(@subject, %{"expected_version" => 2, "criteria" => @criteria})
        )
      )

    {:ok, hash} = Artifacts.put("SOP and input bytes")

    receipt =
      signed_event(
        op,
        "ArtifactCustodyRecordedV1",
        Map.merge(@scope, %{
          "principal_id" => "operator-1",
          "authorization_event_id" => grant.event_id,
          "artifact_digest" => {:bytes, hash}
        })
      )

    {:ok, _} = Log.append(receipt)

    readiness =
      signed_event(
        gov,
        "TaskReadinessDefinedV1",
        Map.merge(@subject, %{
          "expected_version" => 3,
          "artifact_requirements" => %{"input" => {:bytes, hash}},
          "predecessor_ids" => [],
          "sop_digest" => {:bytes, hash}
        })
      )

    {:ok, _} = Log.append(readiness)

    command = fn type, version, more ->
      signed_event(
        op,
        type,
        @subject
        |> Map.merge(actor)
        |> Map.put("expected_version", version)
        |> Map.merge(more)
      )
    end

    {:ok, _} =
      Log.append(
        command.("TaskSOPAcknowledgedV1", 4, %{
          "custody_receipt_id" => receipt.event_id
        })
      )

    {:ok, _} = Log.append(command.("TaskQueuedV1", 5, %{}))

    ready = command.("TaskReadyV1", 6, %{"custody_receipts" => %{"input" => receipt.event_id}})
    {:ok, _} = Log.append(ready)

    {:ok, state} = Log.replay(Projection)
    assert state.tasks[@task_key].state == "ready"
    assert state.tasks[@task_key].version == 7

    %{
      gov: gov,
      op: op,
      agent: agent,
      grant: grant,
      suggester: suggester,
      ready: ready
    }
  end

  def request(ctx, changes \\ %{}) do
    signed_event(
      ctx.op,
      "TaskAgentRunRequestedV1",
      Map.merge(
        Map.merge(@scope, %{
          "run_id" => "run-1",
          "task_id" => "task-1",
          "principal_id" => "operator-1",
          "authorization_event_id" => ctx.grant.event_id,
          "agent_principal_id" => "agent-1",
          "suggester_grant_event_id" => ctx.suggester.event_id,
          "expected_task_version" => 7,
          "source_event_id" => ctx.ready.event_id,
          "definition_digest" => {:bytes, CoopSubstrate.Canonical.hash!(@criteria)},
          "execution_profile_id" => "approved-profile",
          "execution_profile_digest" => {:bytes, <<4::256>>},
          "max_duration_ms" => 30_000,
          "max_output_bytes" => 4096,
          "lifecycle_version" => 1
        }),
        changes
      )
    )
  end

  def access_grant(ctx, action) do
    signed_event(
      ctx.gov,
      "TaskAccessGrantedV1",
      Map.merge(@subject, %{
        "principal_id" => "agent-1",
        "action" => action,
        "expected_task_version" => 7,
        "source_event_id" => ctx.ready.event_id
      })
    )
  end
end
