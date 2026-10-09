defmodule CoopSubstrate.CorrectionsTest do
  @moduledoc """
  Phase 1A acceptance §6 items 7–9 (phase1a_plan step 8): corrections are
  new events referencing the target's hash — the original survives,
  chain-valid; `KeyRotated` is representable and recorded; `chapter_id` is
  enforced on every event at the append gate too.
  """

  use CoopSubstrate.LogCase, async: false

  alias CoopSubstrate.Log
  alias CoopSubstrate.Projections.ChapterStats
  alias CoopSubstrate.Protocol.Envelope

  describe "corrections, not mutations (§6 item 7)" do
    test "a correction references the target; the original survives, chain-valid" do
      member = new_member()

      {:ok, [mistaken]} = Log.append(signed_test_event(member, note: "mistaken", amount_minor: 999))
      {:ok, target_hash} = Envelope.event_hash(mistaken)

      correction =
        signed_event(member, "CorrectionRecorded", %{
          "target_event_hash" => {:bytes, target_hash},
          "reason" => "amount entered as 999, should be 99"
        })

      {:ok, [recorded]} = Log.append(correction)

      # The original is still in the log, byte-identical and chain-valid.
      {:ok, all} = Log.read_all()
      assert Enum.map(all, & &1.event_id) == [mistaken.event_id, recorded.event_id]
      assert Enum.at(all, 0) == mistaken
      assert Log.verify_chains() == :ok

      # The correction points at exactly the original's hash.
      assert recorded.payload["target_event_hash"] == {:bytes, target_hash}

      # The projection sees the correction as one more event, not a rewrite.
      {:ok, state} = Log.replay(ChapterStats)
      assert state.counts["chapter-genesis"] == 2
    end

    test "the log module exposes no mutation or deletion API" do
      exported = Log.__info__(:functions) |> Keyword.keys() |> Enum.map(&Atom.to_string/1)

      refute Enum.any?(exported, fn name ->
               String.contains?(name, "update") or String.contains?(name, "delete") or
                 String.contains?(name, "mutate") or String.contains?(name, "remove")
             end)
    end
  end

  describe "key rotation (§6 item 9)" do
    test "KeyRotated is representable, recorded, and lands in its member key stream" do
      member = new_member()

      rotation =
        signed_event(member, "KeyRotated", %{
          "member_id" => "member-7",
          "old_key_id" => member.signer.key_id,
          "new_key_id" => "k-2026",
          "new_pubkey" => {:bytes, :crypto.strong_rand_bytes(32)}
        })

      {:ok, [recorded]} = Log.append(rotation)
      assert recorded.stream_id == "chapter-genesis/keys/member-7"

      {:ok, [from_log]} = Log.read_stream("chapter-genesis/keys/member-7")
      assert from_log == recorded
      assert Log.verify_chains() == :ok
    end
  end

  describe "chapter_id enforcement (§6 item 8)" do
    test "the envelope layer rejects a missing chapter_id" do
      member = new_member()

      assert {:error, :chapter_id_required} =
               Envelope.new(%{
                 chapter_id: nil,
                 type: "TestProjectionEvent",
                 payload: %{"note" => "x", "amount_minor" => 1},
                 signers: [member.signer],
                 timestamp_ms: System.system_time(:millisecond)
               })
    end

    test "the append gate rejects a hand-built envelope without chapter_id" do
      member = new_member()
      signed = signed_test_event(member)

      assert {:error, {:reject, 0, :chapter_id_required}} =
               Log.append(%{signed | chapter_id: nil})

      assert {:error, {:reject, 0, :chapter_id_required}} =
               Log.append(%{signed | chapter_id: ""})

      assert Log.head().global_seq == 0
    end
  end
end
