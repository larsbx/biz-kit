defmodule ResearchCore.SignedReviewsTest do
  use ExUnit.Case, async: true

  alias ResearchCore.{Access, SignedReviews}

  @scope {"chapter", "museum", "dialect"}

  setup do
    {pubkey, private_key} = :crypto.generate_key(:eddsa, :ed25519)
    actor = {:narrator, "n1"}
    {:ok, record} = Access.new_record(@scope, "rec1", ["n1"], "council")

    intent = %{
      scope: @scope,
      record_id: "rec1",
      actor: actor,
      action: :grant,
      material: :transcript,
      audience: :public,
      expected_revision: 0,
      key_id: "n1-device",
      key_epoch: 4
    }

    authority = %{
      scope: @scope,
      actor: actor,
      active: true,
      key_id: "n1-device",
      key_epoch: 4,
      public_key: pubkey
    }

    {:ok, bytes} = SignedReviews.signing_bytes(intent)
    signature = :crypto.sign(:eddsa, :none, bytes, [private_key, :ed25519])

    %{
      record: record,
      intent: intent,
      authority: authority,
      signature: signature,
      private_key: private_key
    }
  end

  test "an exact Ed25519 signature applies a narrator review but cannot publish alone", c do
    assert {:ok, next} =
             SignedReviews.verify_and_apply(c.record, c.intent, c.signature, c.authority)

    assert next.revision == 1
    refute Access.release_eligible?(next, @scope, :transcript, :public)
  end

  test "a forged or malformed signature is refused", c do
    assert {:error, :invalid_review_signature} =
             SignedReviews.verify_and_apply(c.record, c.intent, <<0::512>>, c.authority)

    assert {:error, :invalid_review_signature} =
             SignedReviews.verify_and_apply(c.record, c.intent, "short", c.authority)
  end

  test "all signed intent fields are bound and no extension fields are ignored", c do
    for {field, value} <- [
          {:scope, {"chapter", "museum", "other"}},
          {:record_id, "rec2"},
          {:actor, {:narrator, "n2"}},
          {:action, :revoke},
          {:material, :audio},
          {:audience, :research},
          {:expected_revision, 1},
          {:key_id, "other-device"},
          {:key_epoch, 5}
        ] do
      tampered = Map.put(c.intent, field, value)

      refute match?(
               {:ok, _},
               SignedReviews.verify_and_apply(c.record, tampered, c.signature, c.authority)
             )
    end

    assert {:error, :invalid_review_intent} =
             SignedReviews.signing_bytes(Map.put(c.intent, :sponsor_id, "funding"))
  end

  test "current key authority must match the signer, scope and epoch", c do
    for change <- [
          %{active: false},
          %{actor: {:sponsor, "university"}},
          %{key_id: "other-device"},
          %{key_epoch: 5},
          %{scope: {"chapter", "museum", "elsewhere"}},
          %{public_key: <<0::256>>}
        ] do
      refute match?(
               {:ok, _},
               SignedReviews.verify_and_apply(
                 c.record,
                 c.intent,
                 c.signature,
                 Map.merge(c.authority, change)
               )
             )
    end

    assert {:error, :review_authority_not_current} =
             SignedReviews.verify_and_apply(c.record, c.intent, c.signature, nil)
  end

  test "the same signed intent cannot be replayed after a revision change", c do
    assert {:ok, revised} =
             SignedReviews.verify_and_apply(c.record, c.intent, c.signature, c.authority)

    assert {:error, :record_or_revision_mismatch} =
             SignedReviews.verify_and_apply(revised, c.intent, c.signature, c.authority)
  end

  test "a sponsor role cannot be signed as cultural consent", c do
    assert {:error, :invalid_review_intent} =
             SignedReviews.signing_bytes(%{
               c.intent
               | actor: {:sponsor, "university"}
             })

    assert {:error, :invalid_review_intent} =
             SignedReviews.signing_bytes(%{c.intent | action: :pay})
  end

  test "a separately signed community decision plus narrator decision permits only named material",
       c do
    assert {:ok, narrator_approved} =
             SignedReviews.verify_and_apply(c.record, c.intent, c.signature, c.authority)

    {community_pub, community_secret} = :crypto.generate_key(:eddsa, :ed25519)

    community_intent = %{
      c.intent
      | actor: {:community, "council"},
        key_id: "council-key",
        expected_revision: 1
    }

    community_authority = %{
      c.authority
      | actor: {:community, "council"},
        key_id: "council-key",
        public_key: community_pub
    }

    {:ok, bytes} = SignedReviews.signing_bytes(community_intent)
    community_signature = :crypto.sign(:eddsa, :none, bytes, [community_secret, :ed25519])

    assert {:ok, approved} =
             SignedReviews.verify_and_apply(
               narrator_approved,
               community_intent,
               community_signature,
               community_authority
             )

    assert Access.release_eligible?(approved, @scope, :transcript, :public)
    refute Access.release_eligible?(approved, @scope, :audio, :public)
  end

  test "a correctly signed, current withdrawal denies future releases", c do
    {:ok, narrator_approved} =
      SignedReviews.verify_and_apply(c.record, c.intent, c.signature, c.authority)

    {community_pub, community_secret} = :crypto.generate_key(:eddsa, :ed25519)

    community_intent = %{
      c.intent
      | actor: {:community, "council"},
        key_id: "community-device",
        expected_revision: 1
    }

    community_authority = %{
      c.authority
      | actor: {:community, "council"},
        key_id: "community-device",
        public_key: community_pub
    }

    {:ok, community_bytes} = SignedReviews.signing_bytes(community_intent)

    community_signature =
      :crypto.sign(:eddsa, :none, community_bytes, [community_secret, :ed25519])

    {:ok, approved} =
      SignedReviews.verify_and_apply(
        narrator_approved,
        community_intent,
        community_signature,
        community_authority
      )

    assert Access.release_eligible?(approved, @scope, :transcript, :public)

    withdrawal = %{c.intent | action: :revoke, expected_revision: 2}
    {:ok, withdrawal_bytes} = SignedReviews.signing_bytes(withdrawal)
    withdrawal_sig = :crypto.sign(:eddsa, :none, withdrawal_bytes, [c.private_key, :ed25519])

    assert {:ok, withdrawn} =
             SignedReviews.verify_and_apply(
               approved,
               withdrawal,
               withdrawal_sig,
               c.authority
             )

    refute Access.release_eligible?(withdrawn, @scope, :transcript, :public)
  end

  test "input shapes and unsigned primitive types are refused", c do
    for bad <- [
          Map.put(c.intent, :key_epoch, -1),
          Map.put(c.intent, :expected_revision, 9_223_372_036_854_775_808),
          Map.put(c.intent, :record_id, "../secret"),
          Map.put(c.intent, :material, "audio"),
          Map.put(c.intent, :scope, ["chapter", "museum", "dialect"]),
          Map.delete(c.intent, :key_id)
        ] do
      assert {:error, :invalid_review_intent} = SignedReviews.signing_bytes(bad)
    end
  end
end
