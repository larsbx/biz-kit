defmodule RestaurantHost.ConfigTest do
  use ExUnit.Case, async: true

  alias RestaurantHost.{Config, Restaurant}

  @seed :binary.copy(<<7>>, 32)
  @board_seed :binary.copy(<<9>>, 32)

  defp json(overrides \\ %{}) do
    Map.merge(
      %{
        "chapter" => "chapter-genesis",
        "merchant" => "shop",
        "currency" => "USD",
        "tax_rate" => "0.0825",
        "menu" => [
          %{"id" => "margherita", "name" => "Margherita", "sku" => "MARG", "price_minor" => 1250}
        ],
        "storefront" => %{"device_id" => "storefront", "key_id" => "k-store"},
        "boards" => %{
          "board-1" => %{
            "device_id" => "board-1",
            "key_id" => "k-board",
            "pairing_sha256" => Base.encode16(:crypto.hash(:sha256, "s3cret"), case: :lower)
          }
        }
      },
      overrides
    )
    |> :json.encode()
    |> IO.iodata_to_binary()
  end

  defp env,
    do: %{
      "RESTAURANT_DEVICE_SEED_STOREFRONT" => Base.encode64(@seed),
      "RESTAURANT_DEVICE_SEED_BOARD_1" => Base.encode64(@board_seed)
    }

  test "a restaurant file plus device seeds from the environment builds a restaurant" do
    assert {:ok, config} = Config.parse(json(), env())
    r = Restaurant.build(config)
    assert {r.chapter, r.merchant, r.currency} == {"chapter-genesis", "shop", :USD}
    assert r.storefront.seed == @seed and r.boards["board-1"].seed == @board_seed
    assert Restaurant.pair(r, "board-1", "s3cret") == {:ok, "board-1"}
    assert Restaurant.pair(r, "board-1", "nope") == :error
  end

  test "a seed never comes from the file, and every device needs one" do
    assert Config.parse(json(), Map.delete(env(), "RESTAURANT_DEVICE_SEED_BOARD_1")) ==
             {:error, {:missing_seed, "RESTAURANT_DEVICE_SEED_BOARD_1"}}

    assert Config.parse(json(), %{env() | "RESTAURANT_DEVICE_SEED_STOREFRONT" => "c2hvcnQ="}) ==
             {:error, {:invalid_seed, "RESTAURANT_DEVICE_SEED_STOREFRONT"}}

    file_seed =
      json(%{"storefront" => %{"device_id" => "storefront", "key_id" => "k", "seed" => "x"}})

    assert Config.parse(file_seed, env()) == {:error, {:unexpected_field, "storefront", "seed"}}
  end

  test "malformed files are refused with a reason" do
    assert Config.parse("{", env()) == {:error, :invalid_json}
    assert Config.parse(json(%{"currency" => "usd"}), env()) == {:error, {:invalid, "currency"}}
    assert Config.parse(json(%{"menu" => []}), env()) == {:error, {:invalid, "menu"}}
    assert Config.parse(json(%{"tax_rate" => "abc"}), env()) == {:error, {:invalid, "tax_rate"}}

    bad_hash = %{
      "board-1" => %{"device_id" => "board-1", "key_id" => "k", "pairing_sha256" => "zz"}
    }

    assert Config.parse(json(%{"boards" => bad_hash}), env()) == {:error, {:invalid, "boards"}}
  end

  test "device IDs, keys and seed references are unambiguous and safe to display" do
    for storefront <- [
          %{"device_id" => "bad\nname", "key_id" => "k-store"},
          %{"device_id" => "storefront", "key_id" => ""}
        ] do
      assert {:error, _} = Config.parse(json(%{"storefront" => storefront}), env())
    end

    for storefront <- [
          %{"device_id" => "board-1", "key_id" => "k-store"},
          %{"device_id" => "storefront", "key_id" => "k-board"}
        ] do
      assert {:error, :ambiguous_devices} =
               Config.parse(json(%{"storefront" => storefront}), env())
    end

    assert {:error, :ambiguous_devices} =
             Config.parse(
               json(),
               %{env() | "RESTAURANT_DEVICE_SEED_BOARD_1" => Base.encode64(@seed)}
             )

    assert {:error, _} = Config.parse(json(%{"chapter" => ""}), env())
  end

  describe "discounts and timezone (decommission D5)" do
    defp with_discounts(rules),
      do: %{
        "menu" => [
          %{
            "id" => "margherita",
            "name" => "Margherita",
            "sku" => "MARG",
            "price_minor" => 1250,
            "discounts" => rules
          }
        ]
      }

    test "each method parses into a catalog rule, and the timezone defaults to UTC" do
      rules = [
        %{"id" => "lunch", "method" => "percent_off", "rate" => "0.2", "hours" => [11, 14]},
        %{"id" => "happy", "method" => "unit_price", "price_minor" => 900, "weekdays" => [5]},
        %{"id" => "3for2", "method" => "buy_x_pay_y", "x" => 3, "y" => 2, "enabled" => false},
        %{
          "id" => "pair",
          "method" => "x_for_amount",
          "x" => 2,
          "amount_minor" => 2000,
          "min_quantity" => 2
        }
      ]

      assert {:ok, config} = Config.parse(json(with_discounts(rules)), env())
      assert config.timezone == "Etc/UTC"

      assert [
               %{id: "lunch", method: :percent_off, rate: rate, hours: {11, 14}},
               %{id: "happy", method: :unit_price, price: price, weekdays: [5]},
               %{id: "3for2", method: :buy_x_pay_y, x: 3, y: 2, enabled: false},
               %{id: "pair", method: :x_for_amount, amount: amount, min_quantity: 2}
             ] = hd(config.menu).discounts

      assert Decimal.equal?(rate, "0.2")
      assert Money.equal?(price, Money.from_integer(900, :USD))
      assert Money.equal?(amount, Money.from_integer(2000, :USD))

      r = Restaurant.build(config)

      assert {:ok, %{discounts: [_, _, _, _]}} =
               CommerceCore.Catalog.quote(r.catalog, "shop", "margherita", nil, :USD)
    end

    test "a malformed rule or an unknown timezone refuses the file" do
      for rule <- [
            %{"id" => "x", "method" => "fixed", "discount" => 5},
            %{"id" => "x", "method" => "percent_off", "rate" => 0.2},
            %{"id" => "x", "method" => "percent_off", "rate" => "1.5"},
            %{"id" => "x", "method" => "buy_x_pay_y", "x" => 2, "y" => 2},
            %{"id" => "x", "method" => "percent_off", "rate" => "0.1", "hours" => [9]},
            %{"id" => "x", "method" => "percent_off", "rate" => "0.1", "colour" => "red"}
          ] do
        assert Config.parse(json(with_discounts([rule])), env()) == {:error, {:invalid, "menu"}},
               inspect(rule)
      end

      ok = %{"id" => "x", "method" => "percent_off", "rate" => "0.1"}

      assert Config.parse(json(with_discounts([ok, ok])), env()) ==
               {:error, {:invalid, "menu"}}

      assert {:ok, %{timezone: "America/New_York"}} =
               Config.parse(json(%{"timezone" => "America/New_York"}), env())

      assert Config.parse(json(%{"timezone" => "Mars/Olympus"}), env()) ==
               {:error, {:invalid, "timezone"}}
    end
  end
end
