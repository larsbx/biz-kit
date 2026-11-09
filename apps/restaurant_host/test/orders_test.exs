defmodule RestaurantHost.OrdersTest do
  use ExUnit.Case, async: false

  alias RestaurantHost.{Orders, World}

  setup do: {:ok, World.build()}

  defp minor(m), do: m |> Money.to_integer_exp() |> elem(1)

  test "a basket is priced from the catalog with sales tax", %{restaurant: r} do
    {:ok, priced} = Orders.price(r, %{"margherita" => 2, "pepperoni" => 1})

    assert Enum.map(priced.lines, &{&1.item_id, &1.quantity, minor(&1.subtotal)}) ==
             [{"margherita", 2, 2500}, {"pepperoni", 1, 1400}]

    # Michigan: 6% of 39.00 is 2.34.
    assert {minor(priced.subtotal), minor(priced.tax), minor(priced.total)} == {3900, 234, 4134}
    assert Orders.price(r, %{"calzone" => 1}) == {:error, :unknown_item}
  end

  test "placing signs the priced snapshot; the same checkout key returns the same order", %{
    restaurant: r
  } do
    {:ok, id} = Orders.place(r, %{"margherita" => 2}, "Ada", "key-1")
    assert {:ok, ^id} = Orders.place(r, %{"margherita" => 2}, "Ada", "key-1")

    assert [%{id: ^id, state: :placed, pickup_name: "Ada", total: 2650, fulfillment: :pickup}] =
             Orders.list(r)

    assert Orders.place(r, %{}, "Ada", "key-2") == {:error, :no_lines}

    assert Orders.place(r, %{"margherita" => 1}, "", "key-3") ==
             {:error, :invalid_checkout_command}

    assert length(Orders.list(r)) == 1
  end

  test "a paired board walks a pickup order to completion; nothing else can", %{restaurant: r} do
    {:ok, id} = Orders.place(r, %{"pepperoni" => 1}, "Grace", "key-1")
    assert Orders.step(r, "board-9", id, :accept, 0) == {:error, :forbidden}

    for {action, v} <- Enum.with_index([:accept, :start_preparing, :mark_ready, :complete]) do
      assert Orders.step(r, "board-1", id, action, v) == :ok
    end

    assert %{state: :completed, version: 4, actions: []} = Orders.get(r, id)
    assert Orders.step(r, "board-1", id, :cancel, 4, "too late") == {:error, :invalid_transition}
  end

  describe "discounts at the merchant's local time (decommission D5)" do
    @lunch %{"id" => "lunch", "method" => "percent_off", "rate" => "0.2", "hours" => [11, 14]}

    setup do
      menu = [
        World.item("margherita", "Margherita", "MARG", 1250, [@lunch]),
        World.item("pepperoni", "Pepperoni", "PEPP", 1400)
      ]

      World.build(menu: menu, timezone: "America/Detroit")
    end

    # Tuesday 10 November 2026, Detroit on EST (UTC−5).
    @lunchtime ~U[2026-11-10 16:30:00Z]
    @afternoon ~U[2026-11-10 20:00:00Z]

    test "a rule in its window discounts its line; tax is on the discounted amount", %{
      restaurant: r
    } do
      {:ok, p} = Orders.price(r, %{"margherita" => 2, "pepperoni" => 1}, @lunchtime)

      assert Enum.map(
               p.lines,
               &{&1.item_id, minor(&1.discount), &1.discount_rule, minor(&1.subtotal)}
             ) ==
               [{"margherita", 500, "lunch", 2000}, {"pepperoni", 0, nil, 1400}]

      # Michigan's 6% of 34.00 is 2.04.
      assert {minor(p.subtotal), minor(p.tax), minor(p.total)} == {3400, 204, 3604}

      {:ok, later} = Orders.price(r, %{"margherita" => 2}, @afternoon)
      assert [%{discount_rule: nil}] = later.lines
      assert minor(later.subtotal) == 2500
    end

    test "the window follows local time across daylight saving", %{restaurant: r} do
      # 15:30 UTC is 11:30 in July (EDT) but 10:30 in November (EST).
      {:ok, summer} = Orders.price(r, %{"margherita" => 1}, ~U[2026-07-14 15:30:00Z])
      {:ok, winter} = Orders.price(r, %{"margherita" => 1}, ~U[2026-11-10 15:30:00Z])
      assert [%{discount_rule: "lunch"}] = summer.lines
      assert [%{discount_rule: nil}] = winter.lines
    end

    test "the Log admits the discounted snapshot and keeps its amounts", %{restaurant: r} do
      {:ok, id} = Orders.place(r, %{"margherita" => 2}, "Ada", "key-d", @lunchtime)
      # 2500 − 500 = 2000; tax 120; total 2120
      assert [%{id: ^id, total: 2120}] = Orders.list(r)
    end
  end

  describe "the storefront shows a line's discount" do
    import Phoenix.ConnTest
    import Phoenix.LiveViewTest
    @endpoint RestaurantHost.Web.Endpoint

    setup do
      tenth = %{"id" => "tenth", "method" => "percent_off", "rate" => "0.1"}
      menu = [World.item("margherita", "Margherita", "MARG", 1250, [tenth])]

      World.build(menu: menu)
    end

    test "discount and discounted total on the page" do
      {:ok, store, _} = live(build_conn(), "/")
      store |> element("#add-margherita") |> render_click()
      store |> element("#add-margherita") |> render_click()
      assert store |> element("#discount-margherita") |> render() =~ "2.50"
      assert store |> element("#total") |> render() =~ "23.85"
    end
  end
end
