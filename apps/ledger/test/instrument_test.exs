defmodule CoopSubstrate.InstrumentTest do
  @moduledoc """
  Phase 2B (docs/phase2b_plan.md P1–P2): the instrument is content-addressed
  data — validated, published, fetched hash-identical, diffed at question
  level; the artifact store verifies on read and fails closed on tamper.
  """

  use CoopSubstrate.LogCase, async: false

  alias CoopSubstrate.Harness.Artifacts
  alias CoopSubstrate.Harness.Instrument

  setup do
    %{steward: new_member("steward")}
  end

  test "artifact store: round-trip, idempotent put, tamper fails closed" do
    binary = :crypto.strong_rand_bytes(128)
    {:ok, hash} = Artifacts.put(binary)
    {:ok, ^hash} = Artifacts.put(binary)
    assert {:ok, ^binary} = Artifacts.get(hash)
    assert {:error, :not_found} = Artifacts.get(:crypto.strong_rand_bytes(32))

    # Corrupt the stored file behind the store's back.
    dir = Application.fetch_env!(:coop_substrate, :artifact_dir)
    path = Path.join(dir, Base.encode16(hash, case: :lower))
    File.write!(path, "tampered")
    assert {:error, :artifact_tampered} = Artifacts.get(hash)
  end

  test "validation: malformed trees are rejected with the defect named" do
    assert :ok = Instrument.validate(Instrument.seed_d())
    assert {:error, :malformed_tree} = Instrument.validate(%{"section" => "D"})

    tree = Instrument.seed_d()

    dup = update_in(tree["personas"], &(&1 ++ [%{"persona" => "x", "questions" => [%{"id" => "co-1", "text" => "again"}]}]))
    assert {:error, :duplicate_question_ids} = Instrument.validate(dup)

    dangling =
      update_in(tree["personas"], fn [p | rest] ->
        [update_in(p["questions"], &(&1 ++ [%{"id" => "co-9", "text" => "?", "follow_ups" => ["co-404"]}])) | rest]
      end)

    assert {:error, {:dangling_follow_ups, ["co-404"]}} = Instrument.validate(dangling)

    assert {:error, {:unknown_section, "Z"}} =
             Instrument.validate(%{tree | "section" => "Z"})
  end

  test "publish → fetch round-trips hash-identical; versions chain; diff is question-level",
       ctx do
    v1 = Instrument.seed_d()
    {key_id, seed} = {ctx.steward.signer.key_id, ctx.steward.seed}

    {:ok, %{version: 1, tree_hash: hash_v1}} = Instrument.publish("chapter-genesis", v1, key_id, seed)
    assert {:ok, ^hash_v1} = Instrument.hash(v1)

    {:ok, fetched} = Instrument.fetch("chapter-genesis", "D", 1)
    assert fetched == v1

    # A changed tree is a NEW content address and a new version — smuggling a
    # "fix" without a version bump is structurally impossible.
    v2 =
      update_in(v1["personas"], fn [p | rest] ->
        [update_in(p["questions"], &(&1 ++ [%{"id" => "co-7", "text" => "What does detention actually cost you per week?"}])) | rest]
      end)

    {:ok, %{version: 2, tree_hash: hash_v2}} = Instrument.publish("chapter-genesis", v2, key_id, seed)
    refute hash_v2 == hash_v1

    assert %{added: ["co-7"], removed: [], changed: []} = Instrument.diff(v1, v2)

    v3 = update_in(v2["personas"], fn [p | rest] ->
      [update_in(p["questions"], fn [q | qs] -> [%{q | "text" => q["text"] <> " Be specific."} | qs] end) | rest]
    end)

    assert %{added: [], removed: [], changed: ["co-1"]} = Instrument.diff(v2, v3)

    # Both versions remain fetchable and distinct.
    assert {:ok, ^v1} = Instrument.fetch("chapter-genesis", "D", 1)
    assert {:ok, ^v2} = Instrument.fetch("chapter-genesis", "D", 2)
    assert {:error, {:unknown_instrument_version, "D", 9}} = Instrument.fetch("chapter-genesis", "D", 9)

    # An invalid tree never reaches the log.
    assert {:error, :malformed_tree} = Instrument.publish("chapter-genesis", %{}, key_id, seed)
  end
end
