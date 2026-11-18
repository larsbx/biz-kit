defmodule RestaurantHost.Slice4GateTest do
  @moduledoc """
  Rebuild slice 4's gate: a pickup order is placed on the web, then accepted,
  prepared and completed on the kitchen board, cash only, every step admitted
  by the signed Log.
  """
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias RestaurantHost.{Orders, World}

  @endpoint RestaurantHost.Web.Endpoint

  setup do: {:ok, World.build() |> Map.put(:conn, build_conn())}

  test "placed on the web, accepted, prepared and completed on the board", ctx do
    {:ok, store, html} = live(ctx.conn, "/")
    assert html =~ "Margherita"

    store |> element("#add-margherita") |> render_click()
    store |> element("#add-margherita") |> render_click()
    assert store |> element("#total") |> render() =~ "26.50"

    store |> form("#place", %{name: "Ada"}) |> render_submit()
    assert render(store) =~ "Received"
    [%{id: id}] = Orders.list(ctx.restaurant)

    board_conn = get(ctx.conn, "/board/pair/board-1/#{ctx.secret}")
    assert redirected_to(board_conn) == "/board"
    {:ok, board, _} = live(recycle(board_conn), "/board")
    assert board |> element("#order-#{id}") |> render() =~ "Ada"

    for action <- ~w(accept start_preparing mark_ready complete) do
      board |> element("##{action}-#{id}") |> render_click()
    end

    assert %{state: :completed, version: 4} = Orders.get(ctx.restaurant, id)
    refute has_element?(board, "#order-#{id}")
    assert render(store) =~ "Picked up"
  end

  test "the page's LiveView client is served from the Phoenix packages", ctx do
    for asset <- ~w(phoenix.min.js phoenix_live_view.min.js) do
      assert ctx.conn |> get("/assets/#{asset}") |> response(200) =~ "Phoenix"
    end
  end

  test "an unpaired or wrongly paired board can do nothing", ctx do
    {:ok, board, _} = live(ctx.conn, "/board")
    assert has_element?(board, "#unpaired")

    assert ctx.conn |> get("/board/pair/board-1/wrong") |> response(403) =~ "Unknown board"
    assert ctx.conn |> get("/board/pair/board-9/#{ctx.secret}") |> response(403)
  end
end
