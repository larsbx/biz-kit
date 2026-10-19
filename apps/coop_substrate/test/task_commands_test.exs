defmodule CoopSubstrate.TaskCommandsTest do
  use CoopSubstrate.LogCase, async: false

  alias CoopSubstrate.Log
  alias CoopSubstrate.Projections.Tasks, as: Projection
  alias CoopSubstrate.Protocol.Envelope
  alias CoopSubstrate.Tasks
  alias CoopSubstrate.ULID

  @scope %{"tenant_id" => "tenant-1", "project_id" => "project-1"}
  @subject Map.put(@scope, "task_id", "task-1")
  @key {"chapter-genesis", "tenant-1", "project-1", "task-1"}

  setup do
    gov = new_member("governance")
    operator = new_member("operator")

    {:ok, _} =
      Log.append(
        signed_event(gov, "RoleKeyDeclared", %{
          "role" => "governance",
          "key_id" => gov.signer.key_id,
          "pubkey" => {:bytes, gov.signer.pubkey}
        })
      )

    grant = grant(gov, operator)
    {:ok, _} = Log.append([grant, baseline(gov)])
    %{gov: gov, operator: operator, grant: grant}
  end

  defp grant(gov, operator, scope \\ @scope) do
    signed_event(
      gov,
      "TaskOperatorGrantedV1",
      Map.merge(scope, %{
        "principal_id" => "principal-1",
        "key_id" => operator.signer.key_id,
        "pubkey" => {:bytes, operator.signer.pubkey}
      })
    )
  end

  defp baseline(gov, subject \\ @subject) do
    signed_event(
      gov,
      "TaskBaselineRecordedV1",
      Map.merge(subject, %{
        "legacy_row_id" => "legacy-task-1",
        "title" => "Propose the integration task",
        "definition_of_done" => "Reviewed implementation",
        "source_digest" => {:bytes, :crypto.hash(:sha256, "preserved source snapshot")},
        "definition_ref" => {:bytes, :crypto.hash(:sha256, "preserved task definition")}
      })
    )
  end

  defp proposal(ctx, changes \\ %{}, attrs \\ []) do
    signed_event(
      ctx.operator,
      "TaskProposedV1",
      Map.merge(
        Map.merge(@subject, %{
          "principal_id" => "principal-1",
          "authorization_event_id" => ctx.grant.event_id,
          "expected_version" => 1,
          "lifecycle_version" => 1
        }),
        changes
      ),
      attrs
    )
  end

  defp revoke(ctx) do
    signed_event(
      ctx.gov,
      "TaskOperatorRevokedV1",
      Map.put(@scope, "authorization_event_id", ctx.grant.event_id)
    )
  end

  defp assert_rejected(command, reason) do
    before_head = Log.head()
    before_state = Log.replay(Projection)
    assert {:error, {:reject, 0, ^reason}} = Log.append(command)
    assert Log.head() == before_head
    assert Log.replay(Projection) == before_state
    assert :ok = Log.verify_chains()
  end

  defp resign(command, actors) do
    unsigned = %{command | signers: Enum.map(actors, & &1.signer), sigs: %{}}

    Enum.reduce(actors, unsigned, fn actor, env ->
      {:ok, signed} = Envelope.sign(env, actor.signer.key_id, actor.seed)
      signed
    end)
  end

  test "all task event types reject distinct same-role keys without restarting the appender",
       ctx do
    other_gov = new_member("governance")
    other_operator = new_member("operator")

    {:ok, _} =
      Log.append(
        signed_event(ctx.gov, "RoleKeyDeclared", %{
          "role" => "governance",
          "key_id" => other_gov.signer.key_id,
          "pubkey" => {:bytes, other_gov.signer.pubkey}
        })
      )

    appender = GenServer.whereis(BizKit.Cluster.Singleton.name(Log))

    commands = [
      resign(grant(ctx.gov, ctx.operator), [ctx.gov, other_gov]),
      resign(revoke(ctx), [other_gov, ctx.gov]),
      resign(baseline(ctx.gov, Map.put(@subject, "task_id", "task-2")), [ctx.gov, other_gov]),
      resign(proposal(ctx), [ctx.operator, other_operator]),
      resign(proposal(ctx), [other_operator, ctx.operator])
    ]

    for command <- commands do
      assert length(Enum.uniq(Enum.map(command.signers, & &1.key_id))) == 2
      assert length(Enum.uniq(Enum.map(command.signers, & &1.pubkey))) == 2
      assert :ok = Envelope.verify(command)

      for _attempt <- 1..3 do
        assert_rejected(command, :task_signer_cardinality)
        assert GenServer.whereis(BizKit.Cluster.Singleton.name(Log)) == appender
        assert Process.alive?(appender)
      end
    end

    assert {:ok, _} = Tasks.propose(proposal(ctx))
    assert GenServer.whereis(BizKit.Cluster.Singleton.name(Log)) == appender
  end

  test "invalid governance signatures and malformed signer collections are safe to retry", ctx do
    appender = GenServer.whereis(BizKit.Cluster.Singleton.name(Log))
    command = baseline(ctx.gov, Map.put(@subject, "task_id", "task-2"))
    invalid = %{command | sigs: %{ctx.gov.signer.key_id => <<0::512>>}}

    for _attempt <- 1..3 do
      assert_rejected(invalid, {:invalid_signature, ctx.gov.signer.key_id})
      assert_rejected(%{command | signers: []}, :signers_required)
      assert_rejected(%{command | signers: nil}, :signers_required)
      assert_rejected(%{command | signers: [%{}]}, :bad_signer)
      assert GenServer.whereis(BizKit.Cluster.Singleton.name(Log)) == appender
      assert Process.alive?(appender)
    end

    assert {:ok, _} = Log.append(command)
    assert {:ok, _} = Tasks.propose(proposal(ctx))
    assert GenServer.whereis(BizKit.Cluster.Singleton.name(Log)) == appender
  end

  test "proposal is durable, typed, signed, and rebuilt from the ledger alone", ctx do
    command = proposal(ctx, %{}, timestamp_ms: 1)
    {:ok, result} = Tasks.propose(command)
    assert result.task_version == 2
    assert result.global_seq == 4
    assert result.event_id == command.event_id

    {:ok, state} = Log.replay(Projection)
    assert %{state: "proposed", version: 2, last_event_id: id} = state.tasks[@key]
    assert id == command.event_id

    assert {:ok, %{tasks: %{@key => %{state: "inbox", version: 1}}}} =
             Log.replay(Projection, as_of: 3)

    {:ok, records} = Log.export_stream("chapter-genesis/tasks/tenant-1/project-1/task-1")
    {:ok, verified} = Log.verify_export(records)
    rebuilt = Enum.reduce(verified, Projection.init(), &Projection.handle_event/2)
    assert rebuilt.tasks == state.tasks
    assert :ok = Log.verify_chains()
    assert Log.replay(Projection) == {:ok, state}
  end

  test "append gate serializes competing commands and rejects the stale one", ctx do
    results =
      [proposal(ctx), proposal(ctx)]
      |> Enum.map(fn command -> Task.async(fn -> Tasks.propose(command) end) end)
      |> Enum.map(&Task.await/1)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert {:error, {:reject, 0, {:stale_task_version, 1, 2}}} in results
    assert Log.head().global_seq == 4
  end

  test "duplicate retry returns its original acknowledgement after restart and revocation", ctx do
    command = proposal(ctx)
    assert {:ok, result} = Tasks.propose(command)
    {:ok, _} = Log.append(revoke(ctx))
    restart_log()
    before_head = Log.head()
    assert Tasks.propose(command) == {:ok, result}
    assert Log.head() == before_head
    assert_rejected(proposal(ctx), :task_grant_revoked)
  end

  test "reuse of a command ID with different signed content is refused", ctx do
    command = proposal(ctx)
    {:ok, _} = Tasks.propose(command)
    changed = proposal(ctx, %{"principal_id" => "another-principal"}, event_id: command.event_id)
    assert_rejected(changed, :task_command_id_conflict)

    assert {:error, {:reject, 0, {:missing_signature, _}}} = Tasks.propose(%{command | sigs: %{}})
  end

  test "scope, principal, signer, and revocation are checked on direct append", ctx do
    assert_rejected(proposal(ctx, %{"tenant_id" => "tenant-2"}), :task_grant_scope_mismatch)
    assert_rejected(proposal(ctx, %{"project_id" => "project-2"}), :task_grant_scope_mismatch)
    assert_rejected(proposal(ctx, %{}, chapter_id: "chapter-two"), :task_grant_scope_mismatch)
    assert_rejected(proposal(ctx, %{"principal_id" => "principal-2"}), :task_principal_mismatch)
    rogue = %{ctx | operator: new_member("operator")}
    assert_rejected(proposal(rogue), :task_operator_key_mismatch)
    {:ok, _} = Log.append(revoke(ctx))
    assert_rejected(proposal(ctx), :task_grant_revoked)
  end

  test "new governance paths fail closed before declaration and after revocation", ctx do
    other = new_member("governance")

    assert_rejected(
      grant(other, ctx.operator),
      {:role_key_not_declared, "governance", other.signer.key_id}
    )

    {:ok, _} =
      Log.append(
        signed_event(ctx.gov, "RoleKeyDeclared", %{
          "role" => "governance",
          "key_id" => other.signer.key_id,
          "pubkey" => {:bytes, other.signer.pubkey}
        })
      )

    {:ok, _} =
      Log.append(
        signed_event(other, "RoleKeyRevoked", %{
          "role" => "governance",
          "key_id" => ctx.gov.signer.key_id
        })
      )

    assert_rejected(
      baseline(ctx.gov, Map.put(@subject, "task_id", "task-2")),
      {:role_key_not_declared, "governance", ctx.gov.signer.key_id}
    )
  end

  test "new namespaces need declared governance, not a fabricated membership", ctx do
    fresh =
      signed_event(ctx.gov, "TaskBaselineRecordedV1", baseline(ctx.gov).payload,
        chapter_id: "new-namespace"
      )

    assert_rejected(fresh, :task_governance_not_declared)

    rogue_grant =
      signed_event(ctx.gov, "TaskOperatorGrantedV1", ctx.grant.payload,
        chapter_id: "new-namespace"
      )

    assert_rejected(rogue_grant, :task_governance_not_declared)
  end

  test "batch rejection does not commit an earlier revocation", ctx do
    before_head = Log.head()

    assert {:error, {:reject, 1, :task_grant_revoked}} = Log.append([revoke(ctx), proposal(ctx)])

    assert Log.head() == before_head
    assert {:ok, _} = Tasks.propose(proposal(ctx))
  end

  test "store append failure changes neither the authoritative task nor retry state", ctx do
    id = ULID.generate()

    {:ok, _} =
      Log.append(
        signed_event(
          new_member(),
          "TestProjectionEvent",
          %{"note" => "reserve the ID", "amount_minor" => 0},
          event_id: id
        )
      )

    before_head = Log.head()
    before_state = Log.replay(Projection)
    assert {:error, {:store_append_failed, _}} = Tasks.propose(proposal(ctx, %{}, event_id: id))

    assert {:error, {:store_append_failed, _}} =
             CoopSubstrate.Buzz.Tasks.propose(proposal(ctx, %{}, event_id: id))

    assert Log.head() == before_head
    assert Log.replay(Projection) == before_state
    restart_log()
    assert {:ok, _} = Tasks.propose(proposal(ctx))
  end

  test "projection tampering and unsupported states cannot license an append", ctx do
    {:ok, _} = Tasks.propose(proposal(ctx))
    {:ok, stale_view} = Log.replay(Projection, as_of: 3)
    forged = put_in(stale_view, [:tasks, @key, :state], "inbox")

    assert_rejected(
      proposal(ctx, %{"expected_version" => forged.tasks[@key].version}),
      {:stale_task_version, 1, 2}
    )

    assert_rejected(
      proposal(ctx, %{"expected_version" => 2}),
      {:invalid_task_transition, "proposed", "proposed"}
    )

    assert_rejected(proposal(ctx, %{"lifecycle_version" => 2}), :unsupported_task_lifecycle)
  end

  test "baseline cannot overwrite a task and stream segments cannot alias", ctx do
    assert_rejected(baseline(ctx.gov), :task_already_recorded)
    assert_rejected(proposal(ctx, %{"tenant_id" => "tenant-1/project-1"}), :invalid_task_scope)
    assert_rejected(proposal(ctx, %{"project_id" => ""}), :invalid_task_scope)
    assert_rejected(proposal(ctx, %{"task_id" => "unknown"}), :unknown_task)
  end

  test "Buzz proposal returns a durable receipt without executing or publishing", ctx do
    command = proposal(ctx)
    assert {:ok, result} = CoopSubstrate.Buzz.Tasks.propose(command)
    assert result.receipt.event_id == command.event_id
    assert result.receipt.task_version == 2
    assert result.notification["ledger_event_id"] == command.event_id
    assert result.notification["task_version"] == 2
    assert result.notification["state"] == "proposed"
    assert result.notification["delivery_id"] == "biz-kit:task:" <> command.event_id

    assert result.notification["event_hash"] ==
             Base.encode16(result.receipt.event_hash, case: :lower)

    assert Log.head().global_seq == result.receipt.global_seq
    restart_log()
    head = Log.head()
    assert CoopSubstrate.Buzz.Tasks.propose(command) == {:ok, result}
    assert Log.head() == head
  end

  test "Buzz cannot use membership flags, reactions, or changed signed bytes as commands", ctx do
    head = Log.head()

    for input <- [nil, %{"member" => true, "approved" => true}, %{"reaction" => "thumbs_up"}] do
      assert {:error, :not_a_task_proposal} = CoopSubstrate.Buzz.Tasks.propose(input)
    end

    command = proposal(ctx)
    changed = %{command | payload: Map.put(command.payload, "task_id", "task-2")}

    assert {:error, {:reject, 0, {:invalid_signature, _}}} =
             CoopSubstrate.Buzz.Tasks.propose(changed)

    assert Log.head() == head
  end

  test "Buzz gets no accepted notification for a revoked or stale request", ctx do
    command = proposal(ctx)
    assert {:ok, _} = Tasks.propose(command)

    assert {:error, {:reject, 0, {:stale_task_version, 1, 2}}} =
             CoopSubstrate.Buzz.Tasks.propose(proposal(ctx))

    {:ok, _} = Log.append(revoke(ctx))

    assert {:error, {:reject, 0, :task_grant_revoked}} =
             CoopSubstrate.Buzz.Tasks.propose(proposal(ctx))
  end

  test "Buzz cards are scoped disposable views with ledger Definition of Done", ctx do
    {:ok, _} = Log.append(baseline(ctx.gov, Map.put(@subject, "task_id", "task-2")))
    {:ok, state} = Log.replay(Projection)
    scope = {"chapter-genesis", "tenant-1", "project-1"}
    assert {:ok, cards} = CoopSubstrate.Buzz.Tasks.cards(state, scope)
    assert Enum.map(cards, & &1["task_id"]) == ["task-1", "task-2"]
    card = hd(cards)
    assert card["definition_of_done"] == "Reviewed implementation"

    assert card["definition_ref"] ==
             Base.encode16(elem(state.tasks[@key].definition_ref, 1), case: :lower)

    assert card["task_version"] == 1
    assert card["ledger_event_id"] == state.tasks[@key].last_event_id

    for other <- [
          {"other", "tenant-1", "project-1"},
          {"chapter-genesis", "other", "project-1"},
          {"chapter-genesis", "tenant-1", "other"}
        ] do
      assert {:ok, []} = CoopSubstrate.Buzz.Tasks.cards(state, other)
    end

    assert {:error, :invalid_scope} = CoopSubstrate.Buzz.Tasks.cards(state, nil)

    assert {:error, :invalid_scope} =
             CoopSubstrate.Buzz.Tasks.cards(state, {"", "tenant-1", "project-1"})

    assert {:ok, _} = Tasks.propose(proposal(ctx))
    restart_log()
    {:ok, rebuilt} = Log.replay(Projection)
    assert {:ok, [updated | _]} = CoopSubstrate.Buzz.Tasks.cards(rebuilt, scope)
    assert updated["state"] == "proposed"
    assert updated["task_version"] == 2
    assert card["state"] == "inbox"
  end
end
