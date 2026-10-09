defmodule CoopSubstrate.CheckpointTest do
  @moduledoc """
  Phase 1D step 5 (docs/phase1d_plan.md P6; hand-off acceptance item 16):
  a checkpoint is a self-contained signed blob committing the operator to
  the entire history — verification recomputes the head from raw ledger
  bytes, audits both chains, and validates the signature against the
  chapter's checkpoint keys AS OF the attested position. Tampered ledgers,
  undeclared signers, and forged heads all fail.
  """

  use CoopSubstrate.LogCase, async: false

  alias CoopSubstrate.Log

  @chapter "chapter-genesis"

  setup do
    gov = new_member("governance")
    ck = new_member("checkpoint")

    {:ok, _} =
      Log.append(
        signed_event(gov, "RoleKeyDeclared", %{
          "role" => "governance",
          "key_id" => gov.signer.key_id,
          "pubkey" => {:bytes, gov.signer.pubkey}
        })
      )

    {:ok, _} =
      Log.append(
        signed_event(gov, "RoleKeyDeclared", %{
          "role" => "checkpoint",
          "key_id" => ck.signer.key_id,
          "pubkey" => {:bytes, ck.signer.pubkey}
        })
      )

    # Some substrate history beneath the head.
    steward = new_member("steward")

    {:ok, _} =
      Log.append(
        signed_event(steward, "EntityRegistered", %{
          "entity_id" => "E-carrier-1",
          "class" => "carriers_coop"
        })
      )

    %{gov: gov, ck: ck, steward: steward}
  end

  defp checkpoint!(ck) do
    {:ok, blob} = Log.checkpoint(@chapter, ck.signer.key_id, ck.seed)
    assert is_binary(blob)
    blob
  end

  test "round-trip: emit, verify; still verifies after more appends and a restart", ctx do
    blob = checkpoint!(ctx.ck)
    assert :ok = Log.verify_checkpoint(blob)

    # The head moves on; the historical attestation stays valid (as-of).
    {:ok, _} =
      Log.append(
        signed_event(ctx.steward, "EntityRegistered", %{
          "entity_id" => "E-2",
          "class" => "carriers_coop"
        })
      )

    assert :ok = Log.verify_checkpoint(blob)

    restart_log()
    assert :ok = Log.verify_checkpoint(blob)

    # And a fresh checkpoint over the longer history verifies too.
    assert :ok = Log.verify_checkpoint(checkpoint!(ctx.ck))
  end

  test "an undeclared signer fails verification", _ctx do
    rogue = new_member("checkpoint")
    {:ok, blob} = Log.checkpoint(@chapter, rogue.signer.key_id, rogue.seed)

    assert {:error, {:checkpoint_key_not_declared, @chapter, _}} =
             Log.verify_checkpoint(blob)
  end

  test "a declared key with a forged signature fails", ctx do
    # Claim the declared key_id but sign with a different seed.
    rogue = new_member("checkpoint")
    {:ok, blob} = Log.checkpoint(@chapter, ctx.ck.signer.key_id, rogue.seed)

    assert {:error, :bad_signature} = Log.verify_checkpoint(blob)
  end

  test "registry is read as-of: revocation stops NEW attestations, not history", ctx do
    old_blob = checkpoint!(ctx.ck)

    {:ok, _} =
      Log.append(
        signed_event(ctx.gov, "RoleKeyRevoked", %{
          "role" => "checkpoint",
          "key_id" => ctx.ck.signer.key_id
        })
      )

    # History: the pre-revocation checkpoint still verifies.
    assert :ok = Log.verify_checkpoint(old_blob)

    # New head, revoked key: the as-of registry no longer declares it.
    {:ok, new_blob} = Log.checkpoint(@chapter, ctx.ck.signer.key_id, ctx.ck.seed)

    assert {:error, {:checkpoint_key_not_declared, @chapter, _}} =
             Log.verify_checkpoint(new_blob)
  end

  # Ends on a deliberately forged record; see LogCase.assert_ledger_intact!/0.
  @tag :tampers_ledger
  test "a tampered ledger fails checkpoint verification", ctx do
    blob = checkpoint!(ctx.ck)
    assert :ok = Log.verify_checkpoint(blob)

    with_update_bypass(fn conn ->
      %{num_rows: 1} =
        Postgrex.query!(
          conn,
          "UPDATE events SET data = $1 WHERE event_id IN
             (SELECT event_id FROM stream_events
               WHERE stream_id = (SELECT stream_id FROM streams WHERE stream_uuid = 'ledger')
                 AND stream_version = 2)",
          [:crypto.strong_rand_bytes(64)]
        )
    end)

    assert {:error, _breaks_or_mismatch} = Log.verify_checkpoint(blob)
  end

  test "garbage and forged-head blobs fail closed", ctx do
    assert {:error, _} = Log.verify_checkpoint(<<0, 1, 2, 3>>)

    # A structurally valid blob claiming a position beyond the ledger.
    {:ok, body} =
      CoopSubstrate.Canonical.encode(%{
        "schema" => "CheckpointV1",
        "chapter_id" => @chapter,
        "key_id" => ctx.ck.signer.key_id,
        "global_seq" => 9_999,
        "global_hash" => {:bytes, :crypto.strong_rand_bytes(32)}
      })

    {:ok, forged} =
      CoopSubstrate.Canonical.encode(%{
        "body" => {:bytes, body},
        "signature" => {:bytes, CoopSubstrate.Crypto.sign(body, ctx.ck.seed)}
      })

    assert {:error, {:unknown_global_seq, 9_999}} = Log.verify_checkpoint(forged)
  end
end
