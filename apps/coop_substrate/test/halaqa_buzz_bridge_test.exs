defmodule CoopSubstrate.Halaqa.BuzzBridgeTest do
  use ExUnit.Case, async: true

  alias CoopSubstrate.Halaqa.BuzzBridge

  defp base do
    %{
      "event_id" => "buzz-1",
      "author" => "worker-1",
      "author_signature_valid" => true,
      "member" => true,
      "halaqa_id" => "dispatch-1",
      "charter_hash" => "charter-v1",
      "epoch" => 7,
      "capability" => "dispatch.assignment.create",
      "tool_sort" => "dispatch.write",
      "evidence_grade" => 3,
      "effect" => %{"load" => "L-1", "worker" => "worker-1"},
      "attestation" => %{"type" => "TypedAttestation", "revision" => 1},
      "delegation" => %{
        "id" => "del-1",
        "basis" => "inherited",
        "active" => true,
        "capabilities" => ["dispatch.assignment.create"],
        "tools" => ["dispatch.write"],
        "recipient_classes" => ["task_delegator"],
        "delegate_class" => "task_delegator",
        "may_delegate" => true,
        "remaining_depth" => 1,
        "purpose" => "dispatch:L-1",
        "parent_purpose" => "dispatch:*",
        "revoked" => false
      },
      "policy" => %{
        "min_evidence" => 2,
        "allowed_tools" => ["dispatch.write"],
        "current_charter_hash" => "charter-v1",
        "current_epoch" => 7
      }
    }
  end

  test "P1 valid authorship is not authority" do
    assert {:refused, :missing_delegation, _} =
             BuzzBridge.resolve(Map.delete(base(), "delegation"))
  end

  test "P2 membership is insufficient" do
    input = base() |> Map.delete("delegation") |> Map.put("member", true)
    assert {:refused, :missing_delegation, _} = BuzzBridge.resolve(input)
  end

  test "P3 only typed attestation changes authorization" do
    input = put_in(base(), ["attestation", "type"], "Reaction")
    assert {:refused, :invalid_attestation, _} = BuzzBridge.resolve(input)
  end

  test "P4 delegation must be active and permit the capability" do
    assert {:refused, :inactive_delegation, _} =
             BuzzBridge.resolve(put_in(base(), ["delegation", "active"], false))
  end

  test "P5 context binds halaqa charter and epoch" do
    assert {:refused, :context_mismatch, _} = BuzzBridge.resolve(put_in(base(), ["epoch"], 6))
  end

  test "P6 evidence and tool ceilings fail closed" do
    assert {:refused, :insufficient_evidence, _} =
             BuzzBridge.resolve(put_in(base(), ["evidence_grade"], 1))

    assert {:refused, :tool_not_allowed, _} =
             BuzzBridge.resolve(put_in(base(), ["tool_sort"], "shell.root"))
  end

  test "P7 commitment is appended before execution" do
    {:admitted, certificate, _} = BuzzBridge.resolve(base())
    parent = self()

    append = fn record ->
      send(parent, {:append, record})
      :ok
    end

    execute = fn effect ->
      send(parent, {:execute, effect})
      {:ok, "receipt-1"}
    end

    assert {:ok, _receipt} = BuzzBridge.commit_and_execute(certificate, append, execute)
    assert_receive {:append, %{kind: :pre_effect}}
    assert_receive {:execute, _}
  end

  test "P7 adversarial sibling: failed append invokes no adapter" do
    {:admitted, certificate, _} = BuzzBridge.resolve(base())
    parent = self()

    assert {:error, :durable_append_failed} =
             BuzzBridge.commit_and_execute(
               certificate,
               fn _ -> {:error, :durable_append_failed} end,
               fn _ -> send(parent, :forbidden_effect) end
             )

    refute_receive :forbidden_effect
  end

  test "P8 refusal produces one record and no effect" do
    {:refused, reason, card} = BuzzBridge.resolve(put_in(base(), ["member"], false))
    assert reason == :not_member
    assert card["kind"] == "refused"
    refute Map.has_key?(card, "effect")
  end

  test "P9 certificate effect hash binds execution bytes" do
    {:admitted, certificate, _} = BuzzBridge.resolve(base())
    assert :ok = BuzzBridge.verify_effect(certificate, base()["effect"])

    assert {:error, :effect_hash_mismatch} =
             BuzzBridge.verify_effect(certificate, %{"changed" => true})
  end

  test "P10 replay is idempotent and changed bytes conflict" do
    {:admitted, certificate, _} = BuzzBridge.resolve(base())
    assert {:execute, state} = BuzzBridge.reserve(certificate, %{})
    assert {:duplicate, ^state} = BuzzBridge.reserve(certificate, state)
    changed = %{certificate | effect_hash: :crypto.strong_rand_bytes(32)}
    assert {:error, :idempotency_conflict} = BuzzBridge.reserve(changed, state)
  end

  test "P11 resolution is deterministic across map construction order" do
    reversed = base() |> Enum.reverse() |> Map.new()
    assert BuzzBridge.resolve(base()) == BuzzBridge.resolve(reversed)
  end

  test "P12 projection rebuild cannot mutate ledger state" do
    {:admitted, certificate, card} = BuzzBridge.resolve(base())
    ledger = [certificate]
    assert ledger == BuzzBridge.rebuild_projection(ledger, [card]).ledger
    assert ledger == BuzzBridge.rebuild_projection(ledger, []).ledger
  end

  test "P13 exercise right does not imply delegation right" do
    input = put_in(base(), ["delegation", "may_delegate"], false)

    assert {:error, :delegation_not_permitted} =
             BuzzBridge.delegate(input, %{"class" => "task_delegator"})
  end

  test "P14 recipient class is constrained" do
    assert {:error, :recipient_class_not_allowed} =
             BuzzBridge.delegate(base(), %{"class" => "constitutive_agent"})
  end

  test "P15 inherited delegation depth is finite" do
    input = put_in(base(), ["delegation", "remaining_depth"], 0)

    assert {:error, :delegation_depth_exhausted} =
             BuzzBridge.delegate(input, %{"class" => "task_delegator"})
  end

  test "P16 child purpose stays within parent purpose" do
    assert {:error, :purpose_amplification} =
             BuzzBridge.delegate(base(), %{"class" => "task_delegator", "purpose" => "finance:*"})
  end

  test "P17 constitutive issuance requires charter office provenance" do
    input = put_in(base(), ["delegation", "basis"], "constitutive")
    assert {:refused, :missing_office_provenance, _} = BuzzBridge.resolve(input)
  end

  test "P18 parent revocation blocks uncommitted descendants" do
    input = put_in(base(), ["delegation", "revoked"], true)
    assert {:refused, :delegation_revoked, _} = BuzzBridge.resolve(input)
  end

  test "P19 revocation preserves committed history" do
    {:admitted, certificate, _} = BuzzBridge.resolve(base())
    assert [^certificate] = BuzzBridge.apply_revocation([certificate], "del-1")
  end

  test "P20 orchestrator and invoked actor remain distinct" do
    assert {:error, :actor_separation_required} =
             BuzzBridge.invoke(%{"orchestrator" => "agent-1", "target" => "agent-1"})

    assert {:ok, _} =
             BuzzBridge.invoke(%{
               "orchestrator" => "agent-1",
               "target" => "agent-2",
               "signatures" => ["sig-1", "sig-2"]
             })
  end
end
