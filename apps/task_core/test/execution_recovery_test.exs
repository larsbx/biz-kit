defmodule TaskCore.ExecutionRecoveryTest do
  use ExUnit.Case, async: true
  alias TaskCore.ExecutionRecovery

  @row %{
    effect_id: "effect-1",
    epoch: 2,
    version: 4,
    phase: "leased",
    backend_ref: "backend-1",
    expired: true,
    deadline_expired: false,
    max_output_bytes: 4096
  }
  defp observation(state) do
    %{
      effect_id: "effect-1",
      epoch: 2,
      backend_ref: "backend-1",
      state: state,
      verified: true,
      final: true,
      receipt: "host-verified-bound-receipt",
      within_budget: true,
      candidate_bytes: "candidate"
    }
  end

  test "expired live backend is adopted; expiry alone and unknown outcomes never authorize a retry" do
    assert {:ok, :adopt} = ExecutionRecovery.decide(@row, observation(:running))

    assert {:error, :unverified_backend_outcome} =
             ExecutionRecovery.decide(@row, observation(:unknown))

    assert {:error, _} = ExecutionRecovery.decide(@row, %{})
    assert {:ok, :retry_pending} = ExecutionRecovery.decide(@row, observation(:absent))

    assert {:error, :unverified_backend_outcome} =
             ExecutionRecovery.decide(@row, %{observation(:absent) | final: false})
  end

  test "wrong effect, epoch, backend and unverified receipts are rejected" do
    for {field, value} <- [
          effect_id: "other",
          epoch: 1,
          backend_ref: "other",
          verified: false,
          receipt: nil
        ] do
      assert {:error, _} =
               ExecutionRecovery.decide(@row, Map.put(observation(:running), field, value))
    end

    assert {:error, :invalid_effect_snapshot} =
             ExecutionRecovery.decide(%{}, observation(:running))
  end

  test "lost handle can be recovered by a verified immutable effect reference" do
    assert {:ok, :adopt} =
             ExecutionRecovery.decide(%{@row | backend_ref: nil}, observation(:running))

    assert {:ok, :recover_candidate} =
             ExecutionRecovery.decide(%{@row | backend_ref: nil}, observation(:candidate))
  end

  test "budget exhaustion requests termination instead of resetting the budget" do
    row = %{@row | deadline_expired: true}
    assert {:ok, :request_termination} = ExecutionRecovery.decide(row, observation(:running))
    assert {:ok, :request_termination} = ExecutionRecovery.decide(row, observation(:absent))
    # The host must separately verify a candidate completed BEFORE its deadline.
    assert {:ok, :recover_candidate} = ExecutionRecovery.decide(row, observation(:candidate))
  end

  test "cancellation requests are not termination proof and late candidates cannot escape cancellation" do
    row = %{@row | phase: "cancel_requested"}
    assert {:ok, :request_termination} = ExecutionRecovery.decide(row, observation(:running))
    assert {:ok, :request_termination} = ExecutionRecovery.decide(row, observation(:candidate))
    assert {:ok, :confirm_cancel} = ExecutionRecovery.decide(row, observation(:cancelled))
    assert {:ok, :confirm_cancel} = ExecutionRecovery.decide(row, observation(:absent))
  end

  test "an unexpired lease cannot be stolen or have its candidate admitted by recovery" do
    for state <- [:running, :absent, :candidate] do
      assert {:error, :effect_not_recoverable} =
               ExecutionRecovery.decide(%{@row | expired: false}, observation(state))
    end
  end

  test "candidate recovery requires bounded bytes and an explicit verified duration attestation" do
    for changes <- [
          %{within_budget: false},
          %{candidate_bytes: nil},
          %{candidate_bytes: :binary.copy("x", 4097)}
        ] do
      assert {:error, :candidate_not_verified_within_budget} =
               ExecutionRecovery.decide(@row, Map.merge(observation(:candidate), changes))
    end
  end
end
