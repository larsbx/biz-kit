defmodule CoopSubstrate.ReplayTest do
  @moduledoc """
  Phase 1A acceptance §6 item 6: deterministic replay of a trivial
  projection — replay reproduces state identically, is order-stable (by
  `global_seq`, never timestamps), and is independently testable (the
  projection is a pure fold anyone can run over exported events).
  """

  use CoopSubstrate.LogCase, async: false

  alias CoopSubstrate.Log
  alias CoopSubstrate.Projections.ChapterStats

  test "replay folds the log into per-chapter counts" do
    member = new_member()
    {:ok, _} = Log.append(signed_test_event(member, note: "a"))
    {:ok, _} = Log.append(signed_test_event(member, note: "b"))
    {:ok, _} = Log.append(signed_test_event(member, chapter_id: "chapter-two"))

    {:ok, state} = Log.replay(ChapterStats)
    assert state.counts == %{"chapter-genesis" => 2, "chapter-two" => 1}
  end

  test "replay twice reproduces identical state" do
    member = new_member()
    for note <- ~w(a b c d), do: {:ok, _} = Log.append(signed_test_event(member, note: note))

    {:ok, first} = Log.replay(ChapterStats)
    {:ok, second} = Log.replay(ChapterStats)
    assert first == second
  end

  test "replay order is global_seq, never author timestamps" do
    member = new_member()

    # Author-asserted timestamps deliberately run BACKWARDS relative to
    # append order; the projection must follow the log, not the clock.
    {:ok, _} = Log.append(signed_test_event(member, note: "first", timestamp_ms: 3_000))
    {:ok, _} = Log.append(signed_test_event(member, note: "middle", timestamp_ms: 2_000))
    {:ok, [last]} = Log.append(signed_test_event(member, note: "last", timestamp_ms: 1_000))

    {:ok, state} = Log.replay(ChapterStats)
    assert state.last_event_id["chapter-genesis"] == last.event_id
  end

  test "replay honors as_of" do
    member = new_member()
    {:ok, [first]} = Log.append(signed_test_event(member, note: "a"))
    {:ok, _} = Log.append(signed_test_event(member, note: "b"))

    {:ok, state} = Log.replay(ChapterStats, as_of: 1)
    assert state.counts == %{"chapter-genesis" => 1}
    assert state.last_event_id["chapter-genesis"] == first.event_id
  end

  test "the same fold over an independently verified export matches replay" do
    member = new_member()
    for note <- ~w(a b), do: {:ok, _} = Log.append(signed_test_event(member, note: note))

    {:ok, records} = Log.export_stream("chapter-genesis/test")
    {:ok, envelopes} = Log.verify_export(records)

    independent =
      Enum.reduce(envelopes, ChapterStats.init(), &ChapterStats.handle_event/2)

    assert {:ok, independent} == Log.replay(ChapterStats)
  end

  test "KeyRotated events fold into the key registry" do
    member = new_member()
    new_pubkey = :crypto.strong_rand_bytes(32)

    rotation =
      signed_event(member, "KeyRotated", %{
        "member_id" => "member-1",
        "old_key_id" => member.signer.key_id,
        "new_key_id" => "k-next",
        "new_pubkey" => {:bytes, new_pubkey}
      })

    {:ok, _} = Log.append(rotation)

    {:ok, state} = Log.replay(ChapterStats)
    assert state.keys["member-1"] == %{key_id: "k-next", pubkey: new_pubkey}
  end
end
