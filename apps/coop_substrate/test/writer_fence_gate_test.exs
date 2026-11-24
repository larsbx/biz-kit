defmodule CoopSubstrate.WriterFenceGateTest do
  use ExUnit.Case, async: true

  alias CoopSubstrate.Projections.AdmissionGate, as: Gate
  alias CoopSubstrate.Protocol.Envelope
  alias CoopSubstrate.WriterFence

  @chapter "chapter-fixture"

  # These unsigned structs exercise only the pure gate/fold. They are never
  # signed or appended, and this module never opens a database or installs a fence.
  defp event(type, chapter, payload, suffix) do
    %Envelope{
      event_id: String.duplicate("0", 25) <> suffix,
      chapter_id: chapter,
      type: type,
      payload: payload,
      signers: [],
      timestamp_ms: 0
    }
  end

  defp archive(chapter \\ @chapter, writer \\ "spruce_goose") do
    event(
      "LegacyHistoryArchived",
      chapter,
      %{
        "writer" => writer,
        "manifest_sha256" => String.duplicate("a", 64)
      },
      "1"
    )
  end

  defp fence(writer \\ "spruce_goose") do
    event("LegacyWriterFenced", @chapter, %{"writer" => writer, "reason" => "fixture"}, "2")
  end

  defp gate do
    %{Gate.init() | role_keys: %{{@chapter, "governance"} => %{"fixture" => <<0::256>>}}}
  end

  test "a new fence requires an earlier archive in the same chapter and writer scope" do
    initial = gate()
    assert {:error, :history_not_archived} = WriterFence.check(fence(), initial)

    other_chapter = Gate.handle_event(archive("chapter-other"), initial)
    assert {:error, :history_not_archived} = WriterFence.check(fence(), other_chapter)

    other_writer = Gate.handle_event(archive(@chapter, "another-writer"), initial)
    assert {:error, :history_not_archived} = WriterFence.check(fence(), other_writer)

    prior = Gate.handle_event(archive(), initial)
    assert :ok = WriterFence.check(fence(), prior)
  end

  test "folding old fence-first history remains total and replayable" do
    history = [fence(), archive()]
    first = Enum.reduce(history, gate(), &Gate.handle_event/2)
    second = Enum.reduce(history, gate(), &Gate.handle_event/2)
    assert first == second
    assert MapSet.member?(first.legacy_archived_writers, {@chapter, "spruce_goose"})
  end

  test "eatsbot has no archive prerequisite and other refusal guards remain" do
    assert :ok = WriterFence.check(fence("eatsbot"), gate())
    assert {:error, {:unknown_writer, "unknown"}} = WriterFence.check(fence("unknown"), gate())
    assert {:error, :no_governance} = WriterFence.check(fence(), Gate.init())
  end

  test "a linked order must belong to the requested type, chapter and known writer" do
    for writer <- ["spruce_goose", "eatsbot"] do
      order = fence(writer)
      assert :ok = WriterFence.check_order_scope(order, @chapter, writer)

      for changed <- [
            %{order | type: "LegacyHistoryArchived"},
            %{order | chapter_id: "chapter-other"},
            %{order | payload: %{"writer" => "different-writer", "reason" => "fixture"}}
          ] do
        assert {:error, :fence_order_mismatch} =
                 WriterFence.check_order_scope(changed, @chapter, writer)
      end

      assert {:error, :fence_order_mismatch} =
               WriterFence.check_order_scope(order, "chapter-other", writer)
    end

    assert {:error, :fence_order_mismatch} =
             WriterFence.check_order_scope(fence("unknown"), @chapter, "unknown")
  end

  test "installation binds every consumed order identity field to canonical evidence" do
    order = %{fence() | global_seq: 3}

    verified = %{
      chapter_id: @chapter,
      writer: "spruce_goose",
      fence_event_id: order.event_id,
      fence_global_seq: 3
    }

    assert :ok = WriterFence.check_preflight_order(order, verified)

    # Reusing the same envelope ID in a corrupt derived link is insufficient.
    for changed <- [
          %{order | event_id: "different-order"},
          %{order | type: "LegacyHistoryArchived"},
          %{order | chapter_id: "chapter-other"},
          %{order | payload: %{"writer" => "eatsbot", "reason" => "fixture"}},
          %{order | global_seq: 4},
          %{order | global_seq: 3.0},
          %{order | global_seq: nil}
        ] do
      assert {:error, :fence_order_mismatch} =
               WriterFence.check_preflight_order(changed, verified)
    end

    for evidence <- [
          %{verified | chapter_id: "chapter-other"},
          %{verified | writer: "eatsbot"},
          %{verified | fence_global_seq: 4},
          %{fence_event_id: "different-order"},
          %{fence_event_id: order.event_id},
          %{fence_event_id: nil},
          %{},
          :no_history_required
        ] do
      assert {:error, :fence_order_mismatch} = WriterFence.check_preflight_order(order, evidence)
    end

    assert :ok = WriterFence.check_preflight_order(fence("eatsbot"), :no_history_required)

    assert {:error, :fence_order_mismatch} =
             WriterFence.check_preflight_order(fence("unknown"), :no_history_required)

    assert {:error, :fence_order_mismatch} =
             WriterFence.check_preflight_order(
               %{fence("eatsbot") | type: "LegacyHistoryArchived"},
               :no_history_required
             )
  end
end
