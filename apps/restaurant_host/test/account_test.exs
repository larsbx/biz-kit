defmodule RestaurantHost.AccountTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias BizKit.Identity.{Principal, Sessions}
  alias RestaurantHost.{Orders, World}

  @endpoint RestaurantHost.Web.Endpoint

  setup do
    ada = Principal.new_id()
    grace = Principal.new_id()

    set_env(:restaurant_host, :identity_provider, "test")
    set_env(:biz_kit_identity, :allow_development_provider, true)

    set_env(:biz_kit_identity, :providers, %{
      "test" => {BizKit.Identity.Providers.Development, subject: "ada"}
    })

    set_env(:biz_kit_identity, :bindings, [
      %{issuer: "biz-kit-development", subject: "ada", principal: ada},
      %{issuer: "biz-kit-development", subject: "grace", principal: grace}
    ])

    {:ok, Map.merge(World.build(), %{ada: ada, grace: grace})}
  end

  test "signed-in checkout and history use the authenticated principal", ctx do
    pending = get(build_conn(), "/auth/login")
    uri = pending |> redirected_to() |> URI.parse()
    callback = uri.path <> "?" <> uri.query
    assert build_conn() |> get(callback) |> response(403) =~ "Sign-in failed"

    logged_in = get(recycle(pending), callback)
    assert redirected_to(logged_in) == "/"
    reference = Plug.Conn.get_session(logged_in, :restaurant_identity)
    assert "wsr_" <> _ = reference

    {:ok, storefront, _} = live(recycle(logged_in), "/")
    storefront |> element("#add-margherita") |> render_click()
    render_submit(storefront, "place", %{"name" => "Ada", "principal_id" => ctx.grace})

    assert [%{id: id, principal: principal}] = Orders.list(ctx.restaurant)
    assert principal == ctx.ada

    assert {:ok, _, html} = live(recycle(logged_in), "/account/orders")
    assert html =~ id

    other_token = Sessions.create(ctx.grace, %{issuer: "biz-kit-development", subject: "grace"})

    other =
      Plug.Test.init_test_session(build_conn(), %{
        "restaurant_identity" => Sessions.reference(other_token)
      })

    assert {:ok, _, other_html} = live(other, "/account/orders")
    refute other_html =~ id

    :ok = Sessions.revoke_reference(reference)
    assert recycle(logged_in) |> get("/account/orders") |> redirected_to() == "/"
  end

  test "a paired board requires an allowlisted session when staff sign-in is configured", ctx do
    set_env(:restaurant_host, :staff_principals, [ctx.ada])
    assert {:ok, id} = Orders.place(ctx.restaurant, %{"margherita" => 1}, "Guest", "staff-test")

    paired = get(build_conn(), "/board/pair/board-1/#{ctx.secret}")
    {:ok, board, _} = live(recycle(paired), "/board")
    assert has_element?(board, "#staff-required")
    refute has_element?(board, "#order-#{id}")

    pending = get(recycle(paired), "/auth/login?return=kitchen")
    uri = pending |> redirected_to() |> URI.parse()
    logged_in = get(recycle(pending), uri.path <> "?" <> uri.query)
    assert redirected_to(logged_in) == "/board"
    {:ok, staff, _} = live(recycle(logged_in), "/board")
    assert has_element?(staff, "#accept-#{id}")

    reference = Plug.Conn.get_session(logged_in, :restaurant_identity)
    :ok = Sessions.revoke_reference(reference)
    staff |> element("#accept-#{id}") |> render_click()
    assert has_element?(staff, "#staff-required")
    assert %{state: :placed} = Orders.get(ctx.restaurant, id)
  end

  defp set_env(app, key, value) do
    previous = Application.fetch_env(app, key)
    Application.put_env(app, key, value)

    on_exit(fn ->
      case previous do
        {:ok, old} -> Application.put_env(app, key, old)
        :error -> Application.delete_env(app, key)
      end
    end)
  end
end
