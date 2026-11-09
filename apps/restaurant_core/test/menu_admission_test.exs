defmodule RestaurantCore.MenuAdmissionTest do
  use ExUnit.Case, async: true

  alias RestaurantCore.Admission

  @gov %{key_id: "governance", pubkey: <<1::256>>}
  @board %{key_id: "board", pubkey: <<2::256>>}
  @item %{
    "id" => "meal",
    "sku" => "MEAL",
    "name" => "Meal",
    "price_minor" => 1250,
    "discount_minor" => 250
  }

  defp gate do
    %{
      role_keys: %{{"chapter", "governance"} => %{"governance" => @gov.pubkey}},
      restaurant: Admission.init()
    }
  end

  defp event(type, payload, signer \\ @gov),
    do: %{type: type, payload: payload, signers: [signer], chapter_id: "chapter"}

  test "menu updates require current governance and the exact previous revision" do
    menu = %{
      "merchant_id" => "shop",
      "currency" => "USD",
      "items" => [@item],
      "expected_revision" => 0
    }

    command = event("RestaurantMenuPublishedV1", menu)
    initial = gate()

    assert Admission.check(%{command | signers: [@board]}, initial) ==
             {:error, :restaurant_governance_not_declared}

    for invalid <- [
          [@item, @item],
          [Map.put(@item, "price_minor", 0)],
          [Map.put(@item, "discount_minor", 1251)]
        ] do
      assert Admission.check(put_in(command.payload["items"], invalid), initial) ==
               {:error, :invalid_restaurant_menu}
    end

    assert :ok = Admission.check(command, initial)
    state = Admission.fold(command, initial)

    assert %{revision: 1, currency: "USD", items: [@item]} =
             Admission.menu(state, "chapter", "shop")

    assert nil == Admission.menu(state, "other-chapter", "shop")
    assert nil == Admission.menu(state, "chapter", "other-shop")
    assert Admission.check(command, %{initial | restaurant: state}) == {:error, :stale_menu}
  end

  test "revocation fences the granted key and keeps it from being granted again" do
    grant =
      event("RestaurantDeviceGrantedV1", %{
        "merchant_id" => "shop",
        "device_id" => "board",
        "key_id" => @board.key_id,
        "actor" => "staff",
        "actions" => ["accept"],
        "pubkey" => {:bytes, @board.pubkey}
      })

    initial = gate()
    g = %{initial | restaurant: Admission.fold(grant, initial)}

    revoke =
      event("RestaurantDeviceRevokedV1", %{"merchant_id" => "shop", "key_id" => @board.key_id})

    assert Admission.active_device?(g.restaurant, "chapter", "shop", @board)
    assert :ok = Admission.check(revoke, g)
    revoked = %{g | restaurant: Admission.fold(revoke, g)}
    refute Admission.active_device?(revoked.restaurant, "chapter", "shop", @board)
    assert Admission.check(grant, revoked) == {:error, :restaurant_key_already_granted}
    assert Admission.check(revoke, revoked) == {:error, :restaurant_device_not_active}

    assert Admission.check(
             event("RestaurantOrderStepV1", %{"merchant_id" => "shop"}, @board),
             revoked
           ) ==
             {:error, :forbidden}
  end
end
