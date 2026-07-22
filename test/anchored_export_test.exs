defmodule CoopSubstrate.AnchoredExportTest do
  @moduledoc """
  Phase 12A (docs/phase12a_plan.md): the departure bundle proves
  COMPLETENESS offline. A prefix-truncated stream passes the 6B checks
  (the gap was real) but fails anchored verification; the honest path
  verifies with only (bundle, checkpoint pubkey); V1 checkpoint blobs
  stay valid; no stream id beyond the member's own appears in an
  anchored bundle.
  """

  use CoopSubstrate.LogCase, async: false

  alias CoopSubstrate.Canonical
  alias CoopSubstrate.Export
  alias CoopSubstrate.Log

  @chapter "chapter-genesis"
  @entity "E-carrier-1"

  setup do
    gov = new_member("governance")
    ck = new_member("checkpoint")

    for {role, owner} <- [{"governance", gov}, {"checkpoint", ck}] do
      {:ok, _} =
        Log.append(
          signed_event(gov, "RoleKeyDeclared", %{
            "role" => role,
            "key_id" => owner.signer.key_id,
            "pubkey" => {:bytes, owner.signer.pubkey}
          })
        )
    end

    steward = new_member("steward")
    ada = new_member("member")
    bob = new_member("member")
    :ok = seed_membership!(steward, ada, "M-ada", @entity)
    :ok = seed_membership!(steward, bob, "M-bob", @entity, register_entity: false)

    {:ok, _} =
      Log.append(
        signed_event(steward, "AccrualRuleActivated", %{
          "rule_id" => "capital-accrual-v1",
          "params" => %{}
        })
      )

    for {member_id, amount} <- [{"M-ada", 5_000}, {"M-ada", 2_000}, {"M-bob", 3_000}] do
      {:ok, _} =
        Log.append(
          signed_event(steward, "PatronageRecorded", %{
            "member_id" => member_id,
            "entity_id" => @entity,
            "kind" => "delivery",
            "amount_minor" => amount
          })
        )
    end

    %{ck: ck, steward: steward}
  end

  defp anchored_bundle!(ck) do
    {:ok, blob} = Log.checkpoint(@chapter, ck.signer.key_id, ck.seed)
    {:ok, bundle} = Export.member_bundle(@chapter, "M-ada")
    {:ok, anchored} = Export.anchor(bundle, blob)
    anchored
  end

  test "the honest path verifies fully offline; the truncation gap closes", ctx do
    anchored = anchored_bundle!(ctx.ck)
    pubkey = ctx.ck.signer.pubkey

    assert {:ok, verified} = Export.verify_anchored(anchored, pubkey)
    assert Map.has_key?(verified, "#{@chapter}/patronage/M-ada/#{@entity}")

    # The wrong key proves nothing.
    stranger = new_member("checkpoint")

    assert {:error, :bad_checkpoint_signature} =
             Export.verify_anchored(anchored, stranger.signer.pubkey)

    # Withhold the LAST patronage record: the 6B checks still pass — the
    # gap this phase closes was real — but the anchor catches it.
    stream = "#{@chapter}/patronage/M-ada/#{@entity}"
    truncated = update_in(anchored, [:streams, stream], &Enum.drop(&1, -1))

    assert {:ok, _} = Export.verify(truncated)

    assert {:error, {:stream_head_mismatch, ^stream}} =
             Export.verify_anchored(truncated, pubkey)

    # A stream stripped of its proof cannot ride along silently.
    unproven = update_in(anchored, [:anchor, :proofs], &Map.delete(&1, stream))
    assert {:error, {:stream_unanchored, ^stream}} = Export.verify_anchored(unproven, pubkey)

    assert {:error, :not_anchored} = Export.verify_anchored(Map.delete(anchored, :anchor), pubkey)
  end

  test "checkpoints: V2 round-trips with root recomputation; V1 blobs stay valid; stale anchors error",
       ctx do
    {:ok, blob} = Log.checkpoint(@chapter, ctx.ck.signer.key_id, ctx.ck.seed)
    assert :ok = Log.verify_checkpoint(blob)

    # A hand-built V1 blob (the pre-12A format) still verifies.
    %{global_seq: seq, global_hash: hash} = Log.head()

    {:ok, v1_body} =
      Canonical.encode(%{
        "schema" => "CheckpointV1",
        "chapter_id" => @chapter,
        "key_id" => ctx.ck.signer.key_id,
        "global_seq" => seq,
        "global_hash" => {:bytes, hash}
      })

    {:ok, v1_blob} =
      Canonical.encode(%{
        "body" => {:bytes, v1_body},
        "signature" => {:bytes, CoopSubstrate.Crypto.sign(v1_body, ctx.ck.seed)}
      })

    assert :ok = Log.verify_checkpoint(v1_blob)

    # V1 carries no root: it cannot anchor a bundle.
    {:ok, bundle} = Export.member_bundle(@chapter, "M-ada")
    assert {:error, :checkpoint_not_anchorable} = Export.anchor(bundle, v1_blob)

    # The log moves on; anchoring a NEW bundle at the stale checkpoint
    # errors instead of silently attesting the wrong position.
    {:ok, _} =
      Log.append(
        signed_event(ctx.steward, "PatronageRecorded", %{
          "member_id" => "M-ada",
          "entity_id" => @entity,
          "kind" => "delivery",
          "amount_minor" => 100
        })
      )

    {:ok, moved} = Export.member_bundle(@chapter, "M-ada")
    assert {:error, {:bundle_not_at_checkpoint, _}} = Export.anchor(moved, blob)

    # And a fresh checkpoint still verifies end to end after the append.
    {:ok, fresh} = Log.checkpoint(@chapter, ctx.ck.signer.key_id, ctx.ck.seed)
    assert :ok = Log.verify_checkpoint(fresh)
  end

  test "no roster leak: an anchored bundle names no streams beyond the member's own", ctx do
    anchored = anchored_bundle!(ctx.ck)
    own_streams = anchored.streams |> Map.keys() |> MapSet.new()

    # Proof keys are exactly the bundle streams; proof VALUES are bare
    # sibling hashes — no stream id (in particular, none of M-bob's)
    # appears anywhere in the anchor.
    assert anchored.anchor.proofs |> Map.keys() |> MapSet.new() == own_streams

    for {_stream, proof} <- anchored.anchor.proofs, {side, sibling} <- proof do
      assert side in [:left, :right]
      assert is_binary(sibling) and byte_size(sibling) == 32
    end

    refute anchored |> inspect() |> String.contains?("M-bob")
  end
end
