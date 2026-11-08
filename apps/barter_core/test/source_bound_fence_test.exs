defmodule BarterCore.SourceBoundFenceTest do
  use ExUnit.Case, async: true

  alias BarterCore.SourceBoundFence, as: Fence

  defp source(id, revision \\ 1) do
    %{
      id: id,
      revision: revision,
      digest: :crypto.hash(:sha256, "original:" <> id <> ":" <> Integer.to_string(revision))
    }
  end

  defp plan(intent, sources, chapter \\ "chapter-a") do
    %{chapter: chapter, intent_id: intent, sources: sources}
  end

  defp checks(override \\ %{}) do
    Map.merge(
      %{
        source_authenticated: true,
        consents_verified: true,
        agency_verified: true,
        legal_effect_verified: true,
        policy_allowed: true
      },
      override
    )
  end

  test "two-source admission is a pure reference: never actual legal or financial settlement" do
    original = Fence.new()
    command = plan("round-1", [source("OB-2"), source("OB-1")])

    assert {:ok, next, receipt} = Fence.admit(original, command, checks())
    assert original.commits == 0
    assert next.commits == 1
    assert map_size(next.consumed) == 2
    assert receipt.status == :reference_admitted_not_authoritative
    assert receipt.legal_discharge == :not_established
    assert receipt.financial_settlement == :none
    refute receipt.authoritative_ledger_append

    assert {:ok, ^next, replay} =
             Fence.admit(next, plan("round-1", Enum.reverse(command.sources)), checks())

    assert replay.status == :reference_replay_only
    assert replay.commitment == receipt.commitment
    assert replay.financial_settlement == :none
  end

  test "a second intent cannot consume an original source even under another revision" do
    assert {:ok, committed, _} =
             Fence.admit(Fence.new(), plan("round-1", [source("OB-1"), source("OB-2")]), checks())

    assert {:error, {:source_already_consumed, {"chapter-a", "OB-1"}}} =
             Fence.admit(
               committed,
               plan("round-2", [source("OB-1", 2), source("OB-3")]),
               checks()
             )

    assert committed.commits == 1
    assert map_size(committed.consumed) == 2
  end

  test "different body under the same intent is a permanent source-binding conflict" do
    assert {:ok, committed, _} =
             Fence.admit(Fence.new(), plan("round-1", [source("OB-1"), source("OB-2")]), checks())

    assert {:error, :intent_digest_conflict} =
             Fence.admit(
               committed,
               plan("round-1", [source("OB-1"), source("OB-3")]),
               checks()
             )

    assert {:error, :intent_digest_conflict} =
             Fence.admit(
               committed,
               plan("round-1", [source("OB-1", 2), source("OB-2")]),
               checks()
             )
  end

  test "identical source labels in another chapter are disjoint accounting scopes" do
    first = plan("round-1", [source("OB-1"), source("OB-2")], "chapter-a")
    other = plan("round-1", [source("OB-1"), source("OB-2")], "chapter-b")

    assert {:ok, one, first_receipt} = Fence.admit(Fence.new(), first, checks())
    assert {:ok, two, second_receipt} = Fence.admit(one, other, checks())

    assert two.commits == 2
    refute first_receipt.commitment == second_receipt.commitment
  end

  test "empty, malformed and duplicate source identities are refused" do
    assert {:error, :invalid_reference_plan} =
             Fence.admit(Fence.new(), plan("round-1", []), checks())

    assert {:error, :duplicate_source_id} =
             Fence.admit(
               Fence.new(),
               plan("round-1", [source("OB-1"), source("OB-1", 2)]),
               checks()
             )

    assert {:error, :invalid_source} =
             Fence.admit(
               Fence.new(),
               plan("round-1", [%{source("OB-1") | digest: <<0, 1>>}]),
               checks()
             )

    assert {:error, :invalid_reference_state} =
             Fence.admit(
               %{intents: %{}, consumed: %{}},
               plan("round-1", [source("OB-1")]),
               checks()
             )
  end

  test "all external authority checks fail closed and cannot create a reference commit" do
    command = plan("round-1", [source("OB-1"), source("OB-2")])
    fields = Map.keys(checks())

    for field <- fields do
      assert {:error, :unverified_external_premise} =
               Fence.admit(Fence.new(), command, checks(%{field => false}))
    end

    assert {:error, :invalid_assumed_checks} =
             Fence.admit(Fence.new(), command, %{source_authenticated: true})
  end

  test "retry is inert even when the caller later claims changed authority" do
    command = plan("round-1", [source("OB-1"), source("OB-2")])
    assert {:ok, one, _} = Fence.admit(Fence.new(), command, checks())

    assert {:ok, ^one, replay} =
             Fence.admit(one, command, checks(%{legal_effect_verified: false}))

    assert replay.status == :reference_replay_only
    assert one.commits == 1
  end
end
