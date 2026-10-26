defmodule FederationService.WebFingerTest do
  use ExUnit.Case, async: true
  alias FederationService.WebFinger

  test "only explicit bounded lowercase handles are disclosed" do
    assert WebFinger.handle!(nil) == nil

    for handle <- ["shop", "shop-one", "market.parts", "shop_2"] do
      assert WebFinger.handle!(handle) == handle
    end

    for invalid <- ["", "Shop", ".shop", "shop..other", "shop.", "a/b", "shop@host", String.duplicate("a", 33), 123] do
      assert_raise ArgumentError, fn -> WebFinger.handle!(invalid) end
    end
  end

  test "lookup is exact and does not accept a payload-supplied actor" do
    actor = "https://alpha.example/actors/shop"
    config = %{actor: actor, handle: "shop", private_key: :configured}

    assert {:ok, doc} = WebFinger.document(config, "acct:shop@alpha.example")
    assert doc["subject"] == "acct:shop@alpha.example"
    assert {:ok, ^doc} = WebFinger.document(config, actor)

    for resource <- ["acct:shop@other.example", "acct:admin@alpha.example", "https://evil.example/actors/shop"] do
      assert {:error, :unknown_resource} = WebFinger.document(config, resource)
    end

    assert {:error, :disabled} = WebFinger.document(%{config | handle: nil}, actor)
    assert {:error, :disabled} = WebFinger.document(%{config | private_key: nil}, actor)
  end
end
