defmodule FederationCore.MarketplaceTest do
  use ExUnit.Case, async: true

  alias FederationCore.Marketplace, as: M

  @seller "https://alpha.example/actors/merchant-one"
  @listing "https://alpha.example/market/listings/part-42"
  @activity "https://alpha.example/activities/event-1"
  @metadata_url "https://alpha.example/market/listings/part-42.json"

  defp attrs(overrides \\ %{}) do
    Map.merge(
      %{
        seller_actor: @seller,
        listing_id: @listing,
        revision: 0,
        title: "Replacement part",
        summary: "Publicly advertised inventory, not a reservation.",
        category: "parts",
        price: %{currency: "USD", minor_units: 1_250}
      },
      overrides
    )
  end

  defp metadata! do
    {:ok, metadata} = M.metadata(attrs())
    metadata
  end

  test "round-trip Create and Update only produce quarantine candidates" do
    metadata = metadata!()
    assert {:ok, ^metadata} = M.validate_metadata(metadata, @seller)

    for kind <- [:create, :update] do
      assert {:ok, published} = M.publish(kind, metadata, @activity, @metadata_url)
      assert published["to"] == ["https://www.w3.org/ns/activitystreams#Public"]

      assert {:ok, candidate} =
               M.decode_verified(published, %{verified_actor: @seller})

      assert candidate == %{
               kind: kind,
               actor: @seller,
               activity_id: @activity,
               listing_id: @listing,
               metadata_url: @metadata_url
             }
    end
  end

  test "price metadata is exact-shape, integer-minor-unit or explicitly quote" do
    {:ok, quoted} = M.metadata(attrs(%{price: :quote}))
    assert quoted["price"] == %{"mode" => "quote"}
    assert {:ok, ^quoted} = M.validate_metadata(quoted, @seller)

    assert {:error, :invalid_marketplace_metadata} =
             M.metadata(attrs(%{price: %{currency: "usd", minor_units: 15}}))

    assert {:error, :invalid_marketplace_metadata} =
             M.metadata(attrs(%{price: %{currency: "USD", minor_units: 1.5}}))

    assert {:error, :invalid_marketplace_metadata} =
             M.validate_metadata(Map.put(metadata!(), "customer_email", "private"), @seller)
  end

  test "public discovery refuses private group terms, identities and authority envelopes" do
    for {field, value} <- [
          {"solo_unit_minor", 10_000},
          {"tiers", [%{"min_quantity" => 5, "unit_minor" => 9_000}]},
          {"buyer_id", "https://buyer.example/actors/private"},
          {"consent", "private-canonical-signed-consent"},
          {"contracted_quantity", 5}
        ] do
      private = Map.put(metadata!(), field, value)
      assert {:error, :invalid_marketplace_metadata} = M.validate_metadata(private, @seller)

      assert {:error, :invalid_marketplace_activity} =
               M.publish(:create, private, @activity, @metadata_url)
    end

    for type <- ~w(GroupBuyOfferPostedV1 GroupBuyContractAdmittedV1 GroupBuyConsentV1) do
      assert {:error, :invalid_marketplace_activity} =
               M.decode_verified(
                 %{"type" => type, "payload" => %{"seller_id" => @seller}},
                 %{verified_actor: @seller}
               )
    end
  end

  test "no remote domain may author listing, activity or metadata URLs" do
    assert {:error, :invalid_marketplace_metadata} =
             M.metadata(attrs(%{listing_id: "https://evil.example/l/1"}))

    assert {:error, :invalid_marketplace_activity} =
             M.publish(:create, metadata!(), "https://evil.example/a/1", @metadata_url)

    assert {:error, :invalid_marketplace_activity} =
             M.publish(:create, metadata!(), @activity, "https://evil.example/terms")
  end

  test "remote self-assertions do not count as verified actor identity" do
    {:ok, published} = M.publish(:create, metadata!(), @activity, @metadata_url)

    assert {:error, :invalid_marketplace_activity} =
             M.decode_verified(published, %{verified_actor: "https://evil.example/actors/other"})

    assert {:error, :invalid_marketplace_activity} =
             M.decode_verified(
               Map.put(published, "actor", "https://evil.example/actors/other"),
               %{verified_actor: @seller}
             )
  end

  test "rejects extra fields, private recipient substitution and forged ownership" do
    {:ok, published} = M.publish(:create, metadata!(), @activity, @metadata_url)

    assert {:error, :invalid_marketplace_activity} =
             M.decode_verified(
               Map.put(published, "grant", "admin"),
               %{verified_actor: @seller}
             )

    assert {:error, :invalid_marketplace_activity} =
             M.decode_verified(
               Map.put(published, "to", [@seller]),
               %{verified_actor: @seller}
             )

    forged = put_in(published, ["object", "attributedTo"], "https://evil.example/actors/other")

    assert {:error, :invalid_marketplace_activity} =
             M.decode_verified(forged, %{verified_actor: @seller})
  end

  test "withdrawal produces owner-bound Tombstone, never remote order cancellation" do
    assert {:ok, withdrawal} = M.withdraw(@seller, @listing, @activity)

    assert {:ok, %{kind: :delete, listing_id: @listing}} =
             M.decode_verified(withdrawal, %{verified_actor: @seller})

    assert {:error, :invalid_marketplace_activity} =
             M.withdraw(@seller, "https://evil.example/l/1", @activity)
  end

  test "rejects non-HTTPS, local addresses, userinfo and oversize descriptions" do
    bad = [
      "http://alpha.example/listing",
      "https://127.0.0.1/listing",
      "https://user:pw@alpha.example/listing",
      "https://alpha.local/listing",
      "https://alpha.example/listing#frag"
    ]

    for url <- bad do
      assert {:error, :invalid_marketplace_metadata} =
               M.metadata(attrs(%{listing_id: url}))
    end

    assert {:error, :invalid_marketplace_metadata} =
             M.metadata(attrs(%{summary: String.duplicate("x", 2049)}))
  end
end
