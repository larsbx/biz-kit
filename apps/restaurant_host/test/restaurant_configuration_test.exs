defmodule RestaurantHost.RestaurantConfigurationTest do
  use ExUnit.Case, async: false

  alias RestaurantHost.Restaurant

  setup do
    previous = Application.fetch_env(:restaurant_host, :restaurant)

    on_exit(fn ->
      case previous do
        {:ok, config} -> Application.put_env(:restaurant_host, :restaurant, config)
        :error -> Application.delete_env(:restaurant_host, :restaurant)
      end
    end)

    :ok
  end

  defp config(seed) do
    %{
      chapter: "chapter-a",
      merchant: "shop",
      currency: :USD,
      tax_rate: "0",
      menu: [%{id: "meal", name: "Meal", sku: "MEAL", price_minor: 100}],
      storefront: %{device_id: "storefront", key_id: "k-store", seed: seed},
      boards: %{}
    }
  end

  test "the installed model is reused and explicit replacement refreshes derived keys" do
    first = Restaurant.configure(config(:binary.copy(<<7>>, 32)))
    assert %Restaurant{} = Application.fetch_env!(:restaurant_host, :restaurant)
    assert Restaurant.current() == first
    assert Restaurant.build(first) == first

    second = Restaurant.configure(config(:binary.copy(<<8>>, 32)))
    assert Restaurant.current() == second
    refute first.storefront.signer.pubkey == second.storefront.signer.pubkey
  end

  test "a failed replacement leaves the previous model intact" do
    config = config(:binary.copy(<<7>>, 32))
    previous = Restaurant.configure(config)
    assert_raise KeyError, fn -> Restaurant.configure(Map.delete(config, :merchant)) end
    assert Restaurant.current() == previous
  end

  test "direct configuration replacement remains supported without a stale cache" do
    _ = Restaurant.configure(config(:binary.copy(<<7>>, 32)))
    replacement = %{config(:binary.copy(<<8>>, 32)) | chapter: "chapter-b"}
    Application.put_env(:restaurant_host, :restaurant, replacement)
    assert Restaurant.current().chapter == "chapter-b"
    assert Restaurant.current().storefront.seed == :binary.copy(<<8>>, 32)
  end
end
