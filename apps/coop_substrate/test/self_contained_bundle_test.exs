defmodule CoopSubstrate.SelfContainedBundleTest do
  @moduledoc """
  Phase 12B (docs/phase12b_plan.md): the bundle carries its own trust
  chain. The checkpoint key derives offline from the bundled governance
  stream by replaying the 1D rules (genesis self-certified, successors
  governance-signed, keys as-of the checkpoint position); the genesis
  fingerprint is the only out-of-band bit — optional but urged, returned
  when not pinned; governance-history truncation fails its own anchor
  proof; the 12A explicit-key path is unchanged.
  """

  use CoopSubstrate.LogCase, async: false

  alias CoopSubstrate.Export
  alias CoopSubstrate.Log

  @chapter "chapter-genesis"
  @entity "E-carrier-1"

  setup do
    gov = new_member("governance")
    ck = new_member("checkpoint")

    for {role, owner} <- [{"governance", gov}, {"checkpoint", ck}] do
      declare_role!(gov, role, owner)
    end

    steward = new_member("steward")
    ada = new_member("member")
    :ok = seed_membership!(steward, ada, "M-ada", @entity)

    {:ok, _} =
      Log.append(
        signed_event(steward, "AccrualRuleActivated", %{
          "rule_id" => "capital-accrual-v1",
          "params" => %{}
        })
      )

    {:ok, _} =
      Log.append(
        signed_event(steward, "PatronageRecorded", %{
          "member_id" => "M-ada",
          "entity_id" => @entity,
          "kind" => "delivery",
          "amount_minor" => 5_000
        })
      )

    %{gov: gov, ck: ck, steward: steward}
  end

  defp declare_role!(gov, role, owner) do
    {:ok, _} =
      Log.append(
        signed_event(gov, "RoleKeyDeclared", %{
          "role" => role,
          "key_id" => owner.signer.key_id,
          "pubkey" => {:bytes, owner.signer.pubkey}
        })
      )
  end

  defp revoke_role!(gov, role, owner) do
    {:ok, _} =
      Log.append(
        signed_event(gov, "RoleKeyRevoked", %{
          "role" => role,
          "key_id" => owner.signer.key_id
        })
      )
  end

  defp anchored!(ck) do
    {:ok, blob} = Log.checkpoint(@chapter, ck.signer.key_id, ck.seed)
    {:ok, bundle} = Export.member_bundle(@chapter, "M-ada")
    {:ok, anchored} = Export.anchor(bundle, blob)
    anchored
  end

  test "fully self-contained: no key material passed in; genesis pinnable", ctx do
    anchored = anchored!(ctx.ck)
    genesis = ctx.gov.signer.pubkey

    # The governance stream rides the bundle.
    assert Map.has_key?(anchored.streams, "#{@chapter}/governance")

    # Nothing but the bundle: verification derives the checkpoint key and
    # states its trust root.
    assert {:ok, %{streams: verified, genesis_key: ^genesis}} = Export.verify_anchored(anchored)
    assert Map.has_key?(verified, "#{@chapter}/patronage/M-ada/#{@entity}")

    # Pinning the recorded fingerprint: right key passes, wrong key dies.
    assert {:ok, _} = Export.verify_anchored(anchored, genesis_pubkey: genesis)

    imposter = new_member("governance")

    assert {:error, :genesis_mismatch} =
             Export.verify_anchored(anchored, genesis_pubkey: imposter.signer.pubkey)

    # The 12A explicit-key path is unchanged.
    assert {:ok, %{genesis_key: nil}} =
             Export.verify_anchored(anchored, checkpoint_pubkey: ctx.ck.signer.pubkey)
  end

  test "derivation replays the 1D rules as-of the checkpoint position", ctx do
    # Rotation: the old anchor keeps verifying (its key was declared as-of
    # its position — later revocation never invalidates it), and the new
    # key carries new anchors.
    old_anchor = anchored!(ctx.ck)

    revoke_role!(ctx.gov, "checkpoint", ctx.ck)
    ck2 = new_member("checkpoint")
    declare_role!(ctx.gov, "checkpoint", ck2)

    assert {:ok, %{genesis_key: _}} = Export.verify_anchored(old_anchor)

    new_anchor = anchored!(ck2)
    assert {:ok, _} = Export.verify_anchored(new_anchor)

    # A checkpoint signed by the REVOKED key after its revocation derives
    # to "not declared" — the operator's gate is not consulted, the rules
    # themselves are.
    stale_key_anchor = anchored!(ctx.ck)

    assert {:error, {:checkpoint_key_not_declared, @chapter, _}} =
             Export.verify_anchored(stale_key_anchor)
  end

  test "a truncated governance history fails its own anchor proof", ctx do
    revoke_role!(ctx.gov, "checkpoint", ctx.ck)
    ck2 = new_member("checkpoint")
    declare_role!(ctx.gov, "checkpoint", ck2)

    anchored = anchored!(ck2)
    governance_stream = "#{@chapter}/governance"

    # Hide the revocation + re-declaration: the stream still verifies as a
    # chain prefix, but its head no longer proves into the signed root.
    truncated = update_in(anchored, [:streams, governance_stream], &Enum.drop(&1, -2))

    assert {:error, {:stream_head_mismatch, ^governance_stream}} =
             Export.verify_anchored(truncated)
  end

  test "a bundle without a governance stream fails derivation distinctly", ctx do
    anchored = anchored!(ctx.ck)
    governance_stream = "#{@chapter}/governance"

    stripped =
      anchored
      |> update_in([:streams], &Map.delete(&1, governance_stream))
      |> update_in([:anchor, :proofs], &Map.delete(&1, governance_stream))

    assert {:error, :no_governance_stream} = Export.verify_anchored(stripped)

    # The out-of-band path still covers such bundles.
    assert {:ok, _} = Export.verify_anchored(stripped, checkpoint_pubkey: ctx.ck.signer.pubkey)
  end
end
