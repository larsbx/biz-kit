defmodule CoopSubstrate.HistoryArchiveGovernanceTest do
  use ExUnit.Case, async: true

  alias CoopSubstrate.HistoryArchive.Governance

  @chapter "chapter-fixture"
  @writer "spruce_goose"
  @digest String.duplicate("a", 64)
  @old %{role: "governance", key_id: "old", pubkey: <<1::256>>}
  @new %{role: "governance", key_id: "new", pubkey: <<2::256>>}
  @rogue %{role: "governance", key_id: "rogue", pubkey: <<3::256>>}

  # These are unsigned data fixtures. This tests only historical authority
  # correspondence and selection, never cryptographic authentication, signing,
  # appending, database access, or installation. Production must verified-replay.
  defp event(type, id, payload, signers) do
    %{type: type, event_id: id, payload: payload, signers: signers, chapter_id: @chapter}
  end

  defp declaration(key \\ @old, signers \\ [@old], id \\ "genesis") do
    event(
      "RoleKeyDeclared",
      id,
      %{"role" => "governance", "key_id" => key.key_id, "pubkey" => {:bytes, key.pubkey}},
      signers
    )
  end

  defp revocation(key, signers \\ [@old], id \\ "revoke") do
    event("RoleKeyRevoked", id, %{"role" => "governance", "key_id" => key.key_id}, signers)
  end

  defp archive(id \\ "archive", signers \\ [@old]) do
    event(
      "LegacyHistoryArchived",
      id,
      %{"writer" => @writer, "manifest_sha256" => @digest},
      signers
    )
  end

  defp fence(id \\ "fence", signers \\ [@old]) do
    event("LegacyWriterFenced", id, %{"writer" => @writer, "reason" => "fixture"}, signers)
  end

  defp fold(events) do
    events
    |> Enum.with_index(1)
    |> Enum.reduce(Governance.init(), fn {env, seq}, state ->
      Governance.handle_event(Map.put(env, :global_seq, seq), state)
    end)
  end

  defp select(state, id \\ "archive"),
    do: Governance.select(state, @chapter, @writer, id, @digest)

  test "an exact authorized archive can be selected before any fence exists" do
    state = fold([declaration(), archive()])

    assert {:ok,
            %{
              archive_event_id: "archive",
              archive_global_seq: 2,
              fence_event_id: nil,
              fence_global_seq: nil
            }} = select(state)
  end

  test "selection binds the earliest matching fence, not a later retry" do
    history = [declaration(), archive(), fence(), fence("fence-retry")]
    state = fold(history)

    assert {:ok, %{fence_event_id: "fence", fence_global_seq: 3}} = select(state)
    assert state == fold(history)
  end

  test "a later archive cannot repair a fence-first history" do
    state = fold([declaration(), fence(), archive()])
    assert state.error == nil
    assert {:error, :archive_not_before_fence} = select(state)

    state = fold([declaration(), archive(), fence(), archive("archive-after-fence")])
    assert {:ok, _} = select(state)
    assert {:error, :archive_not_before_fence} = select(state, "archive-after-fence")
  end

  test "exact event identity, scope, and digest are required" do
    state = fold([declaration(), archive(), fence()])
    assert {:error, :archive_record_not_found} = select(state, "missing")
    assert {:error, :archive_record_not_found} = select(state, "fence")

    assert {:error, :archive_record_context_mismatch} =
             Governance.select(state, "other-chapter", @writer, "archive", @digest)

    assert {:error, :archive_record_context_mismatch} =
             Governance.select(state, @chapter, "other-writer", "archive", @digest)

    assert {:error, :archive_record_digest_mismatch} =
             Governance.select(state, @chapter, @writer, "archive", String.duplicate("b", 64))

    for digest <- ["", "sha256:" <> @digest, String.duplicate("A", 64), nil] do
      assert {:error, :invalid_archive_selection} =
               Governance.select(state, @chapter, @writer, "archive", digest)
    end
  end

  test "fences in other chapters or writers do not change the selected order" do
    other_genesis = %{declaration(@old, [@old], "other-genesis") | chapter_id: "other"}
    other_fence = %{fence("other-fence") | chapter_id: "other"}
    eatsbot = put_in(fence("eatsbot-fence"), [:payload, "writer"], "eatsbot")
    state = fold([declaration(), other_genesis, other_fence, eatsbot, archive(), fence()])

    assert {:ok, %{archive_global_seq: 5, fence_event_id: "fence", fence_global_seq: 6}} =
             select(state)
  end

  test "genesis is self-certified using the declared id and bytes" do
    for invalid <- [
          declaration(@old, [@rogue]),
          declaration(@old, [%{@old | pubkey: @new.pubkey}])
        ] do
      assert {:error, {:governance_record_invalid, "genesis", :genesis_must_be_self_signed}} =
               invalid |> List.wrap() |> fold() |> select()
    end

    # Existing genesis rules allow additional self-certified governance signers;
    # only the declared key becomes authorized for subsequent records.
    state = fold([declaration(@old, [@old, @rogue]), archive()])
    assert {:ok, _} = select(state)
  end

  test "archive assertions require governance in their own chapter" do
    for history <- [[archive()], [declaration(), %{archive() | chapter_id: "other"}]] do
      assert {:error, {:governance_record_invalid, "archive", :no_governance}} =
               history |> fold() |> select()
    end
  end

  test "all post-genesis governance signers must match the then-current registry" do
    for signers <- [[@rogue], [%{@old | pubkey: @new.pubkey}], [@old, @rogue]] do
      state = fold([declaration(), archive("archive", signers)])

      assert {:error,
              {:governance_record_invalid, "archive", {:role_key_not_declared, "governance", _}}} =
               select(state)
    end

    state = fold([declaration(), archive(), fence("fence", [@rogue])])

    assert {:error,
            {:governance_record_invalid, "fence", {:role_key_not_declared, "governance", "rogue"}}} =
             select(state)
  end

  test "authorized key rotation preserves old archive authority at its original position" do
    history = [
      declaration(),
      archive(),
      declaration(@new, [@old], "declare-new"),
      revocation(@old, [@new]),
      fence("fence", [@new])
    ]

    assert {:ok, %{archive_global_seq: 2, fence_global_seq: 5}} = history |> fold() |> select()

    state = fold(history ++ [archive("revoked-archive", [@old])])

    assert {:error,
            {:governance_record_invalid, "revoked-archive",
             {:role_key_not_declared, "governance", "old"}}} = select(state)
  end

  test "unauthorized registry changes cannot grant authority" do
    state = fold([declaration(), declaration(@new, [@rogue], "declare-new"), archive()])

    assert {:error,
            {:governance_record_invalid, "declare-new",
             {:role_key_not_declared, "governance", "rogue"}}} = select(state)

    state = fold([declaration(), revocation(@old, [@rogue]), archive()])

    assert {:error,
            {:governance_record_invalid, "revoke",
             {:role_key_not_declared, "governance", "rogue"}}} =
             select(state)
  end

  test "duplicate declarations, unknown revocations, and orphaning governance fail" do
    state = fold([declaration(), declaration(@old, [@old], "duplicate")])

    assert {:error,
            {:governance_record_invalid, "duplicate",
             {:role_key_already_declared, "governance", "old"}}} = select(state)

    state = fold([declaration(), revocation(@rogue)])

    assert {:error,
            {:governance_record_invalid, "revoke", {:unknown_role_key, "governance", "rogue"}}} =
             select(state)

    state = fold([declaration(), revocation(@old)])

    assert {:error, {:governance_record_invalid, "revoke", :cannot_orphan_governance}} =
             select(state)
  end

  test "the canonical prefix must have unique event ids and consecutive positions" do
    state = fold([declaration(), archive(), fence("archive")])
    assert {:error, {:governance_record_invalid, "archive", :duplicate_event_id}} = select(state)

    for seq <- [0, 1, 2.0, 3, nil] do
      state = fold([declaration()])
      state = Governance.handle_event(Map.put(archive(), :global_seq, seq), state)

      assert {:error,
              {:governance_record_invalid, "archive", {:unexpected_global_sequence, 2, ^seq}}} =
               select(state)
    end
  end

  test "unrelated domain events preserve global positions without adding authority" do
    unrelated = event("SomeDomainEvent", "domain", %{}, [])
    state = fold([declaration(), unrelated, archive()])
    assert {:ok, %{archive_global_seq: 3}} = select(state)

    non_governance = put_in(declaration(), [:payload, "role"], "steward")
    state = fold([non_governance, archive()])
    assert {:error, {:governance_record_invalid, "archive", :no_governance}} = select(state)
  end

  test "missing governance signers and malformed archive assertions fail closed" do
    for signers <- [[], nil, [%{@old | role: "steward"}], [%{@old | pubkey: <<1>>}]] do
      state = fold([declaration(), archive("archive", signers)])

      assert {:error, {:governance_record_invalid, "archive", :invalid_governance_record}} =
               select(state)
    end

    invalid_digest = put_in(archive(), [:payload, "manifest_sha256"], "incorrect")
    state = fold([declaration(), invalid_digest])
    assert {:error, {:governance_record_invalid, "archive", :bad_manifest_digest}} = select(state)

    state = fold([revocation(@old)])
    assert {:error, {:governance_record_invalid, "revoke", :genesis_required}} = select(state)
  end
end
