defmodule AgentCore.AttemptsTest do
  use ExUnit.Case, async: true

  alias AgentCore.Attempts

  @effect "agent-run:signed1"
  @base %{
    effect_id: @effect,
    intent_event_id: "signed1",
    run_id: "run1",
    chapter_id: "chapter1",
    tenant_id: "tenant1",
    project_id: "project1",
    execution_profile_id: "approved1",
    execution_profile_digest: {:bytes, <<1::256>>},
    execution: %{
      run_id: "run1",
      ticket: %{
        "chapter_id" => "chapter1",
        "tenant_id" => "tenant1",
        "project_id" => "project1",
        "task_id" => "task1",
        "task_version" => 3,
        "source_event_id" => "task-source1",
        "definition_digest" => String.duplicate("a", 64)
      }
    },
    requirements: %{
      "max_duration_ms" => 30_000,
      "max_output_bytes" => 4096
    }
  }

  defp registered(plan \\ @base) do
    assert {:ok, state, :new} = Attempts.register(Attempts.init(), plan)
    state
  end

  defp leased do
    state = registered()

    assert {:ok, state, lease} =
             Attempts.claim(state, @effect, "worker1", "token1", 1000, 100, 2)

    {state, lease}
  end

  test "one stable signed effect is registered exactly once without storing secrets" do
    state = registered()

    assert {:ok, ^state, :existing} = Attempts.register(state, @base)
    changed_run = put_in(%{@base | run_id: "other"}, [:execution, :run_id], "other")

    assert {:error, :agent_effect_conflict} =
             Attempts.register(state, changed_run)

    changed_ticket = put_in(@base, [:execution, :ticket, "task_version"], 4)

    assert {:error, :agent_effect_conflict} =
             Attempts.register(state, changed_ticket)

    changed_budget = put_in(@base, [:requirements, "max_output_bytes"], 8192)

    assert {:error, :agent_effect_conflict} =
             Attempts.register(state, changed_budget)

    assert {:error, :invalid_agent_effect_descriptor} =
             Attempts.register(state, %{@base | effect_id: "agent-run:other"})

    assert {:error, :invalid_agent_effect_descriptor} =
             Attempts.register(state, Map.put(@base, :execution_profile_digest, "bad"))

    assert {:ok, row} = Attempts.get(state, @effect)
    assert row.descriptor.run_id == "run1"
    refute Map.has_key?(row.descriptor, :ticket)
    refute Map.has_key?(row.descriptor, :adapter)
    refute Map.has_key?(row.descriptor, :credentials)
    assert row.descriptor.task_version == 3
    assert row.descriptor.task_source_event_id == "task-source1"
    assert row.descriptor.max_output_bytes == 4096
    assert row.phase == :pending
    assert row.attempts == 0
  end

  test "exclusive claim and renewal require fresh token and epoch" do
    {state, lease} = leased()
    assert lease.epoch == 1
    assert lease.owner == "worker1"
    assert lease.expires_at_ms == 1100

    assert {:error, :lease_requires_reconciliation} =
             Attempts.claim(state, @effect, "worker2", "token2", 1050, 100, 2)

    assert {:error, :stale_attempt_epoch} =
             Attempts.renew(state, @effect, 0, "token1", 1050, 100)

    assert {:error, :invalid_attempt_token} =
             Attempts.renew(state, @effect, 1, "token2", 1050, 100)

    assert {:ok, extended} =
             Attempts.renew(state, @effect, 1, "token1", 1050, 150)

    assert {:ok, row} = Attempts.get(extended, @effect)
    assert row.lease.expires_at_ms == 1200

    assert {:error, :lease_expired} =
             Attempts.renew(state, @effect, 1, "token1", 1100, 100)
  end

  test "backend handles are immutable, attempt-fenced operational locators" do
    {state, lease} = leased()

    assert {:ok, attached} =
             Attempts.attach_backend(state, @effect, lease.epoch, "token1", 1050, "backend-handle-1")

    assert {:ok, ^attached} =
             Attempts.attach_backend(attached, @effect, lease.epoch, "token1", 1050, "backend-handle-1")

    assert {:error, :backend_reference_conflict} =
             Attempts.attach_backend(attached, @effect, lease.epoch, "token1", 1050, "backend-handle-2")

    assert {:error, :invalid_backend_reference} =
             Attempts.attach_backend(attached, @effect, lease.epoch, "token1", 1050, "../unsafe")

    assert {:error, :invalid_attempt_token} =
             Attempts.attach_backend(attached, @effect, lease.epoch, "wrong", 1050, "other")

    assert {:ok, row} = Attempts.get(attached, @effect)
    assert row.backend_ref == "backend-handle-1"

    assert {:ok, cancelled} = Attempts.request_cancel(attached, @effect)
    assert {:ok, row} = Attempts.get(cancelled, @effect)
    assert row.backend_ref == "backend-handle-1"

    assert {:error, :no_active_attempt} =
             Attempts.attach_backend(cancelled, @effect, lease.epoch, "token1", 1055, "new-handle")
  end

  test "a candidate is never a business completion and stale workers cannot replace it" do
    {state, lease} = leased()
    digest = {:bytes, <<2::256>>}

    assert {:ok, completed} =
             Attempts.candidate(state, @effect, lease.epoch, "token1", 1050, digest)

    assert {:ok, row} = Attempts.get(completed, @effect)
    assert row.phase == :candidate_ready
    assert row.candidate_digest == digest
    assert row.lease == nil

    assert {:error, :no_active_attempt} =
             Attempts.candidate(completed, @effect, 1, "token1", 1055, {:bytes, <<3::256>>})

    assert {:error, :agent_effect_not_claimable} =
             Attempts.claim(completed, @effect, "worker2", "token2", 1060, 100, 2)

    assert {:error, :invalid_candidate_digest} =
             Attempts.candidate(state, @effect, 1, "token1", 1055, "arbitrary output")
  end

  test "expiry cannot automatically create a duplicate backend execution" do
    {state, _lease} = leased()

    assert {:error, :lease_requires_reconciliation} =
             Attempts.claim(state, @effect, "worker2", "token2", 1100, 100, 2)

    assert {:error, :lease_not_expired} =
             Attempts.reconcile_timeout(state, @effect, 1099, {:absent, "not-running-1"})

    assert {:error, :backend_outcome_not_proven} =
             Attempts.reconcile_timeout(state, @effect, 1100, :unknown)

    assert {:error, :backend_outcome_not_proven} =
             Attempts.reconcile_timeout(state, @effect, 1100, :absent)

    assert {:error, :invalid_reconciliation_receipt} =
             Attempts.reconcile_timeout(state, @effect, 1100, {:absent, "../bad"})

    assert {:ok, reconciled} =
             Attempts.reconcile_timeout(state, @effect, 1100, {:absent, "not-running-1"})

    assert {:ok, reclaimed, later} =
             Attempts.claim(reconciled, @effect, "worker2", "token2", 1110, 100, 2)

    assert later.epoch == 2
    assert {:ok, row} = Attempts.get(reclaimed, @effect)
    assert row.attempts == 2
    assert row.reconciliation_receipt == "not-running-1"

    assert {:error, :stale_attempt_epoch} =
             Attempts.candidate(reclaimed, @effect, 1, "token1", 1150, {:bytes, <<4::256>>})

    assert {:error, :lease_requires_reconciliation} =
             Attempts.claim(reclaimed, @effect, "worker3", "token3", 1250, 100, 2)

    assert {:ok, exhausted} = Attempts.reconcile_timeout(reclaimed, @effect, 1250, {:absent, "not-running-2"})

    assert {:error, :attempt_budget_exhausted} =
             Attempts.claim(exhausted, @effect, "worker3", "token3", 1260, 100, 2)
  end

  test "reconciliation recovers already-finished candidate without rerunning" do
    {state, _} = leased()
    digest = {:bytes, <<8::256>>}

    assert {:ok, recovered} =
             Attempts.reconcile_timeout(state, @effect, 1100, {:candidate, digest, "stored-result-1"})

    assert {:ok, row} = Attempts.get(recovered, @effect)
    assert row.phase == :candidate_ready
    assert row.candidate_digest == digest

    assert {:error, :agent_effect_not_claimable} =
             Attempts.claim(recovered, @effect, "worker2", "token2", 1200, 100, 3)
  end

  test "cancel fences every live token, with separate verified termination receipt" do
    {state, lease} = leased()
    assert {:ok, cancelled_requested} = Attempts.request_cancel(state, @effect)

    assert {:ok, row} = Attempts.get(cancelled_requested, @effect)
    assert row.phase == :cancel_requested
    assert row.epoch == lease.epoch + 1

    assert {:error, :no_active_attempt} =
             Attempts.renew(cancelled_requested, @effect, lease.epoch, "token1", 1050, 100)

    assert {:error, :no_active_attempt} =
             Attempts.candidate(cancelled_requested, @effect, lease.epoch, "token1", 1050, {:bytes, <<7::256>>})

    assert {:error, :cancel_requested} =
             Attempts.claim(cancelled_requested, @effect, "worker2", "token2", 1200, 100, 3)

    assert {:ok, ^cancelled_requested} =
             Attempts.request_cancel(cancelled_requested, @effect)

    assert {:error, :invalid_cancel_receipt} =
             Attempts.confirm_cancel(cancelled_requested, @effect, "../unsafe")

    assert {:ok, confirmed} =
             Attempts.confirm_cancel(cancelled_requested, @effect, "backend-termination-123")

    assert {:ok, ^confirmed} =
             Attempts.confirm_cancel(confirmed, @effect, "backend-termination-123")

    assert {:error, :cancel_receipt_conflict} =
             Attempts.confirm_cancel(confirmed, @effect, "different-evidence")
  end

  test "bad clock, lease, claim inputs, and unknown effects fail closed" do
    state = registered()

    assert {:error, :invalid_lease_claim} =
             Attempts.claim(state, @effect, "worker1", "token1", -1, 100, 2)

    assert {:error, :invalid_lease_claim} =
             Attempts.claim(state, @effect, "worker1", "token1", 1000, 300_001, 2)

    assert {:error, :invalid_lease_claim} =
             Attempts.claim(state, @effect, "worker1", "token1", 1000, 100, 0)

    assert {:error, :invalid_lease_claim} =
             Attempts.claim(state, @effect, "worker1", "../bad", 1000, 100, 2)

    assert {:error, :unknown_agent_effect} =
             Attempts.claim(state, "agent-run:unknown", "worker1", "token1", 1000, 100, 2)

    assert {:error, :unknown_agent_effect} =
             Attempts.request_cancel(state, "agent-run:unknown")

    assert {:error, :invalid_operational_projection} = Attempts.get(%{}, @effect)
  end
end
