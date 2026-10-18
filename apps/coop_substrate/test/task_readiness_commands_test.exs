defmodule CoopSubstrate.TaskReadinessCommandsTest do
  use CoopSubstrate.LogCase, async: false
  alias CoopSubstrate.{Log, Tasks}
  alias CoopSubstrate.Projections.Tasks, as: Projection
  alias CoopSubstrate.Harness.Artifacts

  @scope %{"tenant_id" => "tenant-1", "project_id" => "project-1"}
  @subject Map.put(@scope, "task_id", "task-1")
  @key {"chapter-genesis", "tenant-1", "project-1", "task-1"}

  setup do
    previous = Application.get_env(:coop_substrate, :artifact_dir)
    directory = Path.join(System.tmp_dir!(), "readiness-" <> CoopSubstrate.ULID.generate())
    Application.put_env(:coop_substrate, :artifact_dir, directory)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:coop_substrate, :artifact_dir, previous),
        else: Application.delete_env(:coop_substrate, :artifact_dir)

      File.rm_rf!(directory)
    end)

    gov = new_member("governance")
    worker = new_member("operator")

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

    baseline =
      signed_event(
        gov,
        "TaskBaselineRecordedV1",
        Map.merge(@subject, %{
          "legacy_row_id" => "legacy",
          "title" => "Readiness",
          "definition_of_done" => "Done",
          "source_digest" => {:bytes, :crypto.hash(:sha256, "source")},
          "definition_ref" => {:bytes, :crypto.hash(:sha256, "definition")}
        })
      )

    {:ok, _} = Log.append([grant, baseline])
    ctx = %{gov: gov, worker: worker, grant: grant}
    {:ok, _} = Tasks.propose(command(ctx, "TaskProposedV1", 1))
    # Queuing requires a Definition of Done, which can only be defined while proposed.
    {:ok, _} = Log.append(definition(ctx, "task-1", 2))
    {:ok, hash} = Artifacts.put("SOP and input bytes")

    receipt =
      signed_event(
        worker,
        "ArtifactCustodyRecordedV1",
        Map.merge(actor(ctx), %{
          "artifact_digest" => {:bytes, hash}
        })
      )

    {:ok, _} = Log.append(receipt)
    Map.merge(ctx, %{hash: hash, receipt: receipt})
  end

  defp actor(ctx),
    do:
      Map.merge(@scope, %{
        "principal_id" => "worker",
        "authorization_event_id" => ctx.grant.event_id
      })

  defp command(ctx, type, version, extra \\ %{}, attrs \\ []) do
    signed_event(
      ctx.worker,
      type,
      Map.merge(
        Map.merge(actor(ctx), @subject),
        Map.merge(%{"expected_version" => version, "lifecycle_version" => 1}, extra)
      ),
      attrs
    )
  end

  @criteria [%{"id" => "report", "description" => "Report supplied"}]

  defp definition(ctx, task_id, version) do
    signed_event(
      ctx.gov,
      "TaskDoDDefinedV1",
      Map.merge(@scope, %{
        "task_id" => task_id,
        "expected_version" => version,
        "criteria" => @criteria
      })
    )
  end

  defp configure(ctx, version \\ 3, extra \\ %{}) do
    signed_event(
      ctx.gov,
      "TaskReadinessDefinedV1",
      Map.merge(
        @subject,
        Map.merge(
          %{
            "expected_version" => version,
            "artifact_requirements" => %{"input" => {:bytes, ctx.hash}},
            "predecessor_ids" => [],
            "sop_digest" => {:bytes, ctx.hash}
          },
          extra
        )
      )
    )
  end

  defp prepare(ctx) do
    {:ok, _} = Log.append(configure(ctx))

    {:ok, _} =
      Log.append(
        command(ctx, "TaskSOPAcknowledgedV1", 4, %{"custody_receipt_id" => ctx.receipt.event_id})
      )
  end

  defp ready(ctx, version \\ 6),
    do:
      command(ctx, "TaskReadyV1", version, %{
        "custody_receipts" => %{"input" => ctx.receipt.event_id}
      })

  defp reject(command, reason) do
    head = Log.head()
    state = Log.replay(Projection)
    assert {:error, {:reject, 0, ^reason}} = Log.append(command)
    assert Log.head() == head
    assert Log.replay(Projection) == state
  end

  defp await_restart(_pid, 0), do: {:error, :restart_timeout}

  defp await_restart(pid, attempts) do
    case Process.whereis(Log) do
      current when is_pid(current) and current != pid ->
        :ok

      _ ->
        Process.sleep(10)
        await_restart(pid, attempts - 1)
    end
  end

  test "queued and ready are signed, optimistic and recoverable without effects", ctx do
    prepare(ctx)
    queue = command(ctx, "TaskQueuedV1", 5)
    assert {:ok, [accepted]} = Log.append(queue)
    assert {:ok, state} = Log.replay(Projection)
    assert state.tasks[@key].state == "queued"
    restart_log()
    head = Log.head()
    assert {:ok, [^accepted]} = Log.append(queue)
    assert Log.head() == head
    assert {:ok, _} = Log.append(ready(ctx))
    assert {:ok, state} = Log.replay(Projection)
    assert state.tasks[@key].state == "ready"
    assert state.tasks[@key].version == 7
    pid = Process.whereis(Log)
    monitor = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}
    assert :ok = await_restart(pid, 100)
    assert Log.replay(Projection) == {:ok, state}
    assert :ok = Log.verify_chains()
  end

  test "queuing requires a Definition of Done, checked before readiness", ctx do
    {:ok, state} = Log.replay(Projection)
    task = state.tasks[@key]

    baseline =
      signed_event(
        ctx.gov,
        "TaskBaselineRecordedV1",
        Map.merge(@scope, %{
          "task_id" => "task-3",
          "legacy_row_id" => "legacy-3",
          "title" => task.title,
          "definition_of_done" => task.definition_of_done,
          "source_digest" => task.source_digest,
          "definition_ref" => task.definition_ref
        })
      )

    no_dod = %{"task_id" => "task-3"}
    {:ok, _} = Log.append(baseline)
    {:ok, _} = Tasks.propose(command(ctx, "TaskProposedV1", 1, no_dod))

    # Checked right after the transition, before any readiness prerequisite.
    reject(command(ctx, "TaskQueuedV1", 2, no_dod), :dod_not_defined)

    {:ok, _} = Log.append(definition(ctx, "task-3", 2))
    reject(command(ctx, "TaskQueuedV1", 3, no_dod), :readiness_not_defined)
  end

  test "missing configuration and acknowledgment cannot be replaced by caller flags", ctx do
    reject(command(ctx, "TaskQueuedV1", 3), :readiness_not_defined)
    {:ok, _} = Log.append(configure(ctx))
    reject(command(ctx, "TaskQueuedV1", 4), :sop_acknowledgment_required)
    reject(ready(ctx, 4), {:invalid_task_transition, "proposed", "ready"})
  end

  test "stale versions, unsupported lifecycle and forged operator fail closed", ctx do
    prepare(ctx)
    reject(command(ctx, "TaskQueuedV1", 4), {:stale_task_version, 4, 5})

    reject(
      command(ctx, "TaskQueuedV1", 5, %{"lifecycle_version" => 2}),
      :unsupported_task_lifecycle
    )

    rogue = %{ctx | worker: new_member("operator")}
    reject(command(rogue, "TaskQueuedV1", 5), :task_operator_key_mismatch)

    reject(
      command(ctx, "TaskQueuedV1", 5, %{"project_id" => "other"}),
      :task_grant_scope_mismatch
    )

    {:ok, _} =
      Log.append(
        signed_event(
          ctx.gov,
          "TaskOperatorRevokedV1",
          Map.put(@scope, "authorization_event_id", ctx.grant.event_id)
        )
      )

    reject(command(ctx, "TaskQueuedV1", 5), :task_grant_revoked)
  end

  test "replacement requirements invalidate SOP acknowledgment", ctx do
    prepare(ctx)
    {:ok, _} = Log.append(configure(ctx, 5))
    reject(command(ctx, "TaskQueuedV1", 6), :sop_acknowledgment_required)
  end

  test "ready requires exact scoped custody and rechecks actual bytes", ctx do
    prepare(ctx)
    {:ok, _} = Log.append(command(ctx, "TaskQueuedV1", 5))

    reject(
      command(ctx, "TaskReadyV1", 6, %{"custody_receipts" => %{}}),
      :invalid_readiness_receipts
    )

    reject(
      command(ctx, "TaskReadyV1", 6, %{"custody_receipts" => %{"input" => "unknown"}}),
      :unknown_custody_receipt
    )

    path =
      Path.join(
        Application.fetch_env!(:coop_substrate, :artifact_dir),
        Base.encode16(ctx.hash, case: :lower)
      )

    File.write!(path, "replaced")
    reject(ready(ctx), :artifact_tampered)
    File.rm!(path)
    reject(ready(ctx), :not_found)
  end

  test "unknown, self and incomplete predecessors fail closed", ctx do
    reject(configure(ctx, 3, %{"predecessor_ids" => ["unknown"]}), :unknown_predecessor)
    reject(configure(ctx, 3, %{"predecessor_ids" => ["task-1"]}), :invalid_predecessors)
    # Use the already committed baseline shape; no external row is authoritative.
    {:ok, state} = Log.replay(Projection)
    task = state.tasks[@key]

    payload =
      Map.merge(@scope, %{
        "task_id" => "task-2",
        "legacy_row_id" => "legacy-2",
        "title" => task.title,
        "definition_of_done" => task.definition_of_done,
        "source_digest" => task.source_digest,
        "definition_ref" => task.definition_ref
      })

    {:ok, _} = Log.append(signed_event(ctx.gov, "TaskBaselineRecordedV1", payload))
    {:ok, _} = Log.append(configure(ctx, 3, %{"predecessor_ids" => ["task-2"]}))

    {:ok, _} =
      Log.append(
        command(ctx, "TaskSOPAcknowledgedV1", 4, %{"custody_receipt_id" => ctx.receipt.event_id})
      )

    {:ok, _} = Log.append(command(ctx, "TaskQueuedV1", 5))
    reject(ready(ctx), :incomplete_predecessors)
  end

  test "atomic failure and conflicting duplicate IDs never advance projection", ctx do
    prepare(ctx)
    queue = command(ctx, "TaskQueuedV1", 5)
    head = Log.head()

    assert {:error, {:reject, 1, {:stale_task_version, 5, 6}}} =
             Log.append([queue, ready(ctx, 5)])

    assert Log.head() == head
    restart_log()
    assert {:ok, _} = Log.append(queue)

    reject(
      command(ctx, "TaskQueuedV1", 5, %{"principal_id" => "other"}, event_id: queue.event_id),
      :task_command_id_conflict
    )
  end

  test "store failure leaves a queue command retryable after recovery", ctx do
    prepare(ctx)
    id = CoopSubstrate.ULID.generate()

    {:ok, _} =
      Log.append(
        signed_event(
          new_member(),
          "TestProjectionEvent",
          %{"note" => "reserve ID", "amount_minor" => 0},
          event_id: id
        )
      )

    before_state = Log.replay(Projection)
    head = Log.head()

    assert {:error, {:store_append_failed, _}} =
             Log.append(command(ctx, "TaskQueuedV1", 5, %{}, event_id: id))

    assert Log.head() == head
    assert Log.replay(Projection) == before_state
    restart_log()
    assert {:ok, _} = Log.append(command(ctx, "TaskQueuedV1", 5))
  end

  test "reviewer role cannot queue, and new operators must acknowledge personally", ctx do
    prepare(ctx)
    reviewer = %{ctx.worker | signer: %{ctx.worker.signer | role: "reviewer"}}

    valid = command(ctx, "TaskQueuedV1", 5)
    unsigned = %{valid | signers: [reviewer.signer], sigs: %{}}

    {:ok, invalid_role} =
      CoopSubstrate.Protocol.Envelope.sign(unsigned, reviewer.signer.key_id, reviewer.seed)

    assert {:error, {:reject, 0, _}} = Log.append(invalid_role)

    other = new_member("operator")

    grant =
      signed_event(
        ctx.gov,
        "TaskOperatorGrantedV1",
        Map.merge(@scope, %{
          "principal_id" => "worker",
          "key_id" => other.signer.key_id,
          "pubkey" => {:bytes, other.signer.pubkey}
        })
      )

    {:ok, _} = Log.append(grant)

    reject(
      command(%{ctx | worker: other, grant: grant}, "TaskQueuedV1", 5),
      :sop_acknowledgment_required
    )
  end

  test "custody with the wrong digest cannot satisfy readiness", ctx do
    prepare(ctx)
    {:ok, _} = Log.append(command(ctx, "TaskQueuedV1", 5))
    {:ok, hash} = Artifacts.put("different input")

    receipt =
      signed_event(
        ctx.worker,
        "ArtifactCustodyRecordedV1",
        Map.put(actor(ctx), "artifact_digest", {:bytes, hash})
      )

    {:ok, _} = Log.append(receipt)

    reject(
      command(ctx, "TaskReadyV1", 6, %{"custody_receipts" => %{"input" => receipt.event_id}}),
      :custody_digest_mismatch
    )
  end

  test "cross-project custody and batch revocation cannot license readiness", ctx do
    prepare(ctx)
    {:ok, _} = Log.append(command(ctx, "TaskQueuedV1", 5))
    other_scope = Map.put(@scope, "project_id", "project-2")

    grant =
      signed_event(
        ctx.gov,
        "TaskOperatorGrantedV1",
        Map.merge(other_scope, %{
          "principal_id" => "worker",
          "key_id" => ctx.worker.signer.key_id,
          "pubkey" => {:bytes, ctx.worker.signer.pubkey}
        })
      )

    {:ok, _} = Log.append(grant)

    receipt =
      signed_event(
        ctx.worker,
        "ArtifactCustodyRecordedV1",
        Map.merge(other_scope, %{
          "principal_id" => "worker",
          "authorization_event_id" => grant.event_id,
          "artifact_digest" => {:bytes, ctx.hash}
        })
      )

    {:ok, _} = Log.append(receipt)

    reject(
      command(ctx, "TaskReadyV1", 6, %{"custody_receipts" => %{"input" => receipt.event_id}}),
      :task_grant_scope_mismatch
    )

    revoke =
      signed_event(
        ctx.gov,
        "TaskOperatorRevokedV1",
        Map.put(@scope, "authorization_event_id", ctx.grant.event_id)
      )

    head = Log.head()
    assert {:error, {:reject, 1, :task_grant_revoked}} = Log.append([revoke, ready(ctx)])
    assert Log.head() == head
    assert {:ok, _} = Log.append(ready(ctx))
  end

  test "atomic readiness admission and the membership gate match task replay", ctx do
    commands = [
      configure(ctx),
      command(ctx, "TaskSOPAcknowledgedV1", 4, %{"custody_receipt_id" => ctx.receipt.event_id}),
      command(ctx, "TaskQueuedV1", 5),
      ready(ctx)
    ]

    assert {:ok, _} = Log.append(commands)
    assert {:ok, task_state} = Log.replay(Projection)
    assert {:ok, gate} = Log.replay(CoopSubstrate.Projections.Membership)
    assert gate.orchestration == task_state
    assert task_state.tasks[@key].state == "ready"
    restart_log()
    assert {:ok, recovered} = Log.replay(CoopSubstrate.Projections.Membership)
    assert recovered.orchestration == task_state
  end
end
