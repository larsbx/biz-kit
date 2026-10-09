defmodule CoopSubstrate.KeyRecoveryTest do
  @moduledoc """
  Phase 10B (docs/phase10b_plan.md): a lost key is not a lost identity —
  and no single actor can rotate one. Recovery composes an approved,
  unconsumed R item naming exactly this member and key, a governance
  signature the declared registry validates, and the new key certifying
  its own possession. Every leg is load-bearing; consumed items never
  authorize a rollback.
  """

  use CoopSubstrate.LogCase, async: false

  alias CoopSubstrate.Log

  @chapter "chapter-genesis"
  @entity "E-carrier-1"
  @member "M-ada"

  setup do
    steward = new_member("steward")
    member = new_member("member")
    gov = new_member("governance")
    :ok = seed_membership!(steward, member, @member, @entity)

    author = new_member("author")

    {:ok, _} =
      Log.append(
        signed_event(author, "CharterConstantDeclared", %{
          "name" => "cockpit/open_cap",
          "value" => 8
        })
      )

    %{steward: steward, member: member, gov: gov}
  end

  defp declare_governance!(gov) do
    {:ok, _} =
      Log.append(
        signed_event(gov, "RoleKeyDeclared", %{
          "role" => "governance",
          "key_id" => gov.signer.key_id,
          "pubkey" => {:bytes, gov.signer.pubkey}
        })
      )
  end

  defp raise_item!(steward, item_id) do
    {:ok, _} =
      Log.append(
        signed_event(steward, "EscalationRaised", %{
          "item_id" => item_id,
          "process" => "key_recovery",
          "act_type" => "identity_recovery",
          "packet_refs" => ["identity-evidence-artifact"],
          "recommendation" => "recover after in-person verification",
          "bounds" => %{"member_id" => @member},
          "compensation_path" => "revoke via a further recovery round",
          "deadline_ms" => 4_102_444_800_000,
          "basis_ref" => {:bytes, :crypto.hash(:sha256, item_id)}
        })
      )
  end

  defp resolve!(steward, item_id, verdict) do
    {:ok, _} =
      Log.append(
        signed_event(steward, "EscalationResolved", %{
          "item_id" => item_id,
          "verdict" => verdict
        })
      )
  end

  defp recovery(gov, new_key, overrides \\ %{}) do
    payload =
      Map.merge(
        %{
          "member_id" => @member,
          "new_key_id" => new_key.signer.key_id,
          "new_pubkey" => {:bytes, new_key.signer.pubkey},
          "authorization_item_id" => "recovery/#{@member}/#{new_key.signer.key_id}"
        },
        overrides
      )

    multi_signed_event([new_key, gov], "KeyRecoveryRotated", payload)
  end

  defp membership_payload, do: %{"member_id" => @member, "entity_id" => @entity}

  test "the full path: item, approval, dual signature — then the old key is dead", ctx do
    declare_governance!(ctx.gov)
    new_key = new_member("member")
    item_id = "recovery/#{@member}/#{new_key.signer.key_id}"

    raise_item!(ctx.steward, item_id)
    resolve!(ctx.steward, item_id, "approved")

    {:ok, _} = Log.append(recovery(ctx.gov, new_key))

    # The lost key signs nothing anymore; the new key is the member.
    assert {:error, {:reject, _, {:not_the_members_current_key, _}}} =
             Log.append(signed_event(ctx.member, "HardshipDeclared", membership_payload()))

    {:ok, _} = Log.append(signed_event(new_key, "HardshipDeclared", membership_payload()))
    {:ok, _} = Log.append(signed_event(new_key, "HardshipEnded", membership_payload()))

    # Normal self-rotation chains from the recovered key (KeyRotated is a
    # 1A author-role type; the signature is still the recovered key's).
    rotated = new_member("member")
    as_author = %{new_key | signer: %{new_key.signer | role: "author"}}

    {:ok, _} =
      Log.append(
        signed_event(as_author, "KeyRotated", %{
          "member_id" => @member,
          "old_key_id" => new_key.signer.key_id,
          "new_key_id" => rotated.signer.key_id,
          "new_pubkey" => {:bytes, rotated.signer.pubkey}
        })
      )

    assert :ok = Log.verify_chains()
  end

  test "every leg is load-bearing", ctx do
    new_key = new_member("member")
    item_id = "recovery/#{@member}/#{new_key.signer.key_id}"

    # Genesis-trust chapters must grow up first: no declared governance, no
    # recovery.
    assert {:error, {:reject, _, :governance_undeclared}} =
             Log.append(recovery(ctx.gov, new_key))

    declare_governance!(ctx.gov)

    assert {:error, {:reject, _, {:unknown_item, ^item_id}}} =
             Log.append(recovery(ctx.gov, new_key))

    raise_item!(ctx.steward, item_id)

    assert {:error, {:reject, _, {:item_unresolved, ^item_id}}} =
             Log.append(recovery(ctx.gov, new_key))

    # A declined review authorizes nothing.
    declined_key = new_member("member")
    declined_item = "recovery/#{@member}/#{declined_key.signer.key_id}"
    raise_item!(ctx.steward, declined_item)
    resolve!(ctx.steward, declined_item, "declined")

    assert {:error, {:reject, _, {:not_authorized, "declined"}}} =
             Log.append(recovery(ctx.gov, declined_key))

    resolve!(ctx.steward, item_id, "approved")

    # The item names the exact key: citing it for another key dies.
    other_key = new_member("member")

    assert {:error, {:reject, _, {:authorization_subject_mismatch, ^item_id}}} =
             Log.append(recovery(ctx.gov, other_key, %{"authorization_item_id" => item_id}))

    # Self-certification: the member-role signer must BE the new key — the
    # old key cannot stand in for it.
    assert {:error, {:reject, _, :recovery_must_be_self_certified}} =
             Log.append(
               multi_signed_event([ctx.member, ctx.gov], "KeyRecoveryRotated", %{
                 "member_id" => @member,
                 "new_key_id" => new_key.signer.key_id,
                 "new_pubkey" => {:bytes, new_key.signer.pubkey},
                 "authorization_item_id" => item_id
               })
             )

    # An undeclared governance signer is rejected by the role-key registry.
    imposter_gov = new_member("governance")

    assert {:error, {:reject, _, {:role_key_not_declared, "governance", _}}} =
             Log.append(recovery(imposter_gov, new_key))

    # Rotating to the key the member already has is not a recovery.
    current_item = "recovery/#{@member}/#{ctx.member.signer.key_id}"
    raise_item!(ctx.steward, current_item)
    resolve!(ctx.steward, current_item, "approved")

    assert {:error, {:reject, _, :new_key_is_current}} =
             Log.append(recovery(ctx.gov, ctx.member))

    # And the legitimate recovery still lands after all of it.
    {:ok, _} = Log.append(recovery(ctx.gov, new_key))
  end

  test "recovery is repeatable but a consumed item never authorizes a rollback", ctx do
    declare_governance!(ctx.gov)

    key1 = new_member("member")
    item1 = "recovery/#{@member}/#{key1.signer.key_id}"
    raise_item!(ctx.steward, item1)
    resolve!(ctx.steward, item1, "approved")
    {:ok, _} = Log.append(recovery(ctx.gov, key1))

    # Lost again: a fresh item and fresh key recover again.
    key2 = new_member("member")
    item2 = "recovery/#{@member}/#{key2.signer.key_id}"
    raise_item!(ctx.steward, item2)
    resolve!(ctx.steward, item2, "approved")
    {:ok, _} = Log.append(recovery(ctx.gov, key2))

    # The first item is spent: replaying it would roll the member back to
    # key1 on stale authority — unrepresentable.
    assert {:error, {:reject, _, {:item_consumed, ^item1}}} =
             Log.append(recovery(ctx.gov, key1))

    assert :ok = Log.verify_chains()
  end
end
