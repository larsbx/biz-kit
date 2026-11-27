defmodule ResearchCore.AccessTest do
  use ExUnit.Case, async: true

  alias ResearchCore.Access

  @scope {"chapter", "museum", "dialect"}
  @other {"chapter", "museum", "different"}
  @n1 {:narrator, "n1"}
  @n2 {:narrator, "n2"}
  @community {:community, "council"}

  defp record! do
    assert {:ok, record} =
             Access.new_record(@scope, "interview1", ["n2", "n1"], "council")

    record
  end

  defp review!(record, actor, action, material \\ :transcript, audience \\ :public) do
    assert {:ok, updated} =
             Access.review(
               record,
               @scope,
               actor,
               action,
               material,
               audience,
               record.revision
             )

    updated
  end

  test "a record starts restricted with exact project scope and deterministic narrators" do
    record = record!()
    assert record.revision == 0
    assert record.narrator_ids == ["n1", "n2"]
    assert record.scope == @scope
    refute Access.release_eligible?(record, @scope, :audio, :public)
    refute Access.release_eligible?(record, @scope, :transcript, :research)
    refute Access.release_eligible?(record, @scope, :excerpt, :public)
  end

  test "reject malformed projects, records, community IDs and narrators" do
    assert {:error, :invalid_record} = Access.new_record("scope", "rec", ["n1"], "council")
    assert {:error, :invalid_record} = Access.new_record(@scope, "", ["n1"], "council")
    assert {:error, :invalid_record} = Access.new_record(@scope, "rec", [], "council")
    assert {:error, :invalid_record} = Access.new_record(@scope, "rec", ["n1", "n1"], "council")
    assert {:error, :invalid_record} = Access.new_record(@scope, "rec", ["n1"], "")
    assert {:error, :invalid_record} = Access.new_record(@scope, "rec", ["../secret"], "council")

    assert {:error, :invalid_record} =
             Access.new_record(@scope, "rec", Enum.map(1..33, &"n#{&1}"), "council")
  end

  test "every narrator and community authorization is necessary" do
    record = record!()
    by_narrators = record |> review!(@n1, :grant) |> review!(@n2, :grant)
    refute Access.release_eligible?(by_narrators, @scope, :transcript, :public)

    by_community = review!(record, @community, :grant)
    refute Access.release_eligible?(by_community, @scope, :transcript, :public)

    complete = review!(by_narrators, @community, :grant)
    assert Access.release_eligible?(complete, @scope, :transcript, :public)
  end

  test "exhaust all eight combinations of two narrators and one community" do
    actors = [@n1, @n2, @community]

    for mask <- 0..7 do
      record =
        actors
        |> Enum.with_index()
        |> Enum.reduce(record!(), fn {actor, index}, state ->
          if Bitwise.band(mask, Bitwise.bsl(1, index)) != 0 do
            review!(state, actor, :grant)
          else
            state
          end
        end)

      assert Access.release_eligible?(record, @scope, :transcript, :public) == (mask == 7)
    end
  end

  test "sponsorship and ordinary operator status never confer consent" do
    record = record!()

    for actor <- [
          {:sponsor, "university"},
          {:operator, "owner"},
          {:governance, "head"},
          {:community, "other"},
          {:narrator, "unknown"}
        ] do
      assert {:error, :unauthorized_record_reviewer} =
               Access.review(record, @scope, actor, :grant, :transcript, :public, 0)
    end

    refute Access.release_eligible?(record, @scope, :transcript, :public)
  end

  test "audiences and material types never inherit permissions" do
    complete =
      record!()
      |> review!(@n1, :grant, :excerpt, :public)
      |> review!(@n2, :grant, :excerpt, :public)
      |> review!(@community, :grant, :excerpt, :public)

    assert Access.release_eligible?(complete, @scope, :excerpt, :public)
    refute Access.release_eligible?(complete, @scope, :audio, :public)
    refute Access.release_eligible?(complete, @scope, :transcript, :public)
    refute Access.release_eligible?(complete, @scope, :excerpt, :research)
    refute Access.release_eligible?(complete, @scope, :excerpt, :private)
  end

  test "any withdrawal immediately removes future release eligibility" do
    complete =
      record!()
      |> review!(@n1, :grant)
      |> review!(@n2, :grant)
      |> review!(@community, :grant)

    withdrawn = review!(complete, @n1, :revoke)
    refute Access.release_eligible?(withdrawn, @scope, :transcript, :public)
    assert withdrawn.revision == 4

    restored = review!(withdrawn, @n1, :grant)
    assert Access.release_eligible?(restored, @scope, :transcript, :public)

    restricted_again = review!(restored, @community, :revoke)
    refute Access.release_eligible?(restricted_again, @scope, :transcript, :public)
  end

  test "stale, duplicate and unsupported reviews fail closed" do
    record = record!()
    changed = review!(record, @n1, :grant)

    assert {:error, :stale_record_revision} =
             Access.review(changed, @scope, @n2, :grant, :transcript, :public, 0)

    assert {:error, :unchanged_record_review} =
             Access.review(changed, @scope, @n1, :grant, :transcript, :public, 1)

    assert {:error, :unchanged_record_review} =
             Access.review(changed, @scope, @n2, :revoke, :transcript, :public, 1)

    for {action, material, audience} <- [
          {:approve, :transcript, :public},
          {:grant, :image, :public},
          {:grant, :audio, :all}
        ] do
      assert {:error, :invalid_review} =
               Access.review(changed, @scope, @n1, action, material, audience, 1)
    end

    assert changed.revision == 1
    assert MapSet.size(changed.grants) == 1
  end

  test "a review and a release check are pinned to the exact project" do
    record = record!()

    assert {:error, :record_scope_mismatch} =
             Access.review(record, @other, @n1, :grant, :excerpt, :public, 0)

    complete =
      record
      |> review!(@n1, :grant)
      |> review!(@n2, :grant)
      |> review!(@community, :grant)

    refute Access.release_eligible?(complete, @other, :transcript, :public)
    assert Access.release_eligible?(complete, @scope, :transcript, :public)
  end

  test "identical accepted review streams replay deterministically" do
    actions = [
      {@community, :grant, :transcript, :research},
      {@n1, :grant, :transcript, :research},
      {@n2, :grant, :transcript, :research},
      {@n2, :revoke, :transcript, :research},
      {@n2, :grant, :transcript, :research}
    ]

    replay = fn ->
      Enum.reduce(actions, record!(), fn {actor, action, material, audience}, record ->
        review!(record, actor, action, material, audience)
      end)
    end

    first = replay.()
    assert first == replay.()
    assert first.revision == length(actions)
    assert Access.release_eligible?(first, @scope, :transcript, :research)
    refute Access.release_eligible?(first, @scope, :transcript, :public)
  end
end
