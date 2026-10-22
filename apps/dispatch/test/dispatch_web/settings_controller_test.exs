defmodule DispatchWeb.SettingsControllerTest do
  @moduledoc """
  `/settings/users` through the browser path: sign-in, the page, its forms
  (CSRF token and idempotency key included), and Section 23.3's step-up.
  Scenario 15's server half: an administrator manages assignments and still
  opens no operational page until someone else grants them one.
  """

  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  require Ash.Query

  alias Dispatch.Accounts.RoleAssignment
  alias Dispatch.Support.Fixtures
  alias Dispatch.Support.Tokens.StaticVerifier

  @moduletag :integration

  @opts DispatchWeb.Router.init([])

  @session Plug.Session.init(
             store: :cookie,
             key: "_dispatch_session",
             signing_salt: "5xJq0pQe",
             encryption_salt: "Nn4vT2kA"
           )

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Dispatch.Repo)

    carrier = Fixtures.carrier()
    tenant = carrier.id

    definitions =
      Map.new(~w(ADMIN DISPATCHER DRIVER), &{&1, Fixtures.role_definition(tenant, &1)})

    %{user: admin_user, participant: admin} =
      Fixtures.person(tenant, carrier, display_name: "Ada")

    %{participant: driver} = Fixtures.person(tenant, carrier, display_name: "Dan")

    Fixtures.assignment(tenant, carrier, admin, "ADMIN", definition: definitions["ADMIN"])

    %{
      tenant: tenant,
      carrier: carrier,
      definitions: definitions,
      admin_user: admin_user,
      admin: admin,
      driver: driver
    }
  end

  # A browser: each request carries the cookies the previous response set.
  defp request(previous, method, path, params \\ %{}) do
    method
    |> conn(path, params)
    |> put_in([Access.key(:secret_key_base)], secret())
    |> then(&if previous, do: recycle_cookies(&1, previous), else: &1)
    |> Plug.Session.call(@session)
    |> fetch_session()
    |> DispatchWeb.Router.call(@opts)
  end

  defp secret, do: Application.get_env(:dispatch, DispatchWeb.Endpoint)[:secret_key_base]

  defp sign_in(user, opts \\ []) do
    login = request(nil, :get, "/login")
    token = StaticVerifier.token_for(user.oidc_subject, opts)

    signed_in =
      request(login, :post, "/session", %{"_csrf_token" => csrf(login), "token" => token})

    assert signed_in.status == 302
    signed_in
  end

  defp csrf(conn), do: field(conn.resp_body, "_csrf_token")

  defp field(html, name) do
    [_all, value] = Regex.run(~r/name="#{name}" value="([^"]+)"/, html)
    value
  end

  # The grant form's own keys, from the page as drawn.
  defp grant_form(page, participant, definition) do
    [form] = Regex.run(~r/<form id="settings-grant".*?<\/form>/s, page.resp_body)

    %{
      "_csrf_token" => field(form, "_csrf_token"),
      "idempotency_key" => field(form, "idempotency_key"),
      "participant_id" => participant.id,
      "role_definition_id" => definition.id
    }
  end

  defp revoke_form(page, assignment) do
    [form] =
      Regex.run(
        ~r/<li\s+id="settings-assignment-#{assignment.id}".*?<\/form>/s,
        page.resp_body
      )

    %{
      "_csrf_token" => field(form, "_csrf_token"),
      "idempotency_key" => field(form, "idempotency_key"),
      "expected_version" => field(form, "expected_version")
    }
  end

  defp held(ctx, participant) do
    RoleAssignment
    |> Ash.Query.filter(principal_id == ^participant.id and status == :ACTIVE)
    |> Ash.read!(authorize?: false, tenant: ctx.tenant)
  end

  test "an administrator lands on /settings/users, which lists the organization", ctx do
    browser = sign_in(ctx.admin_user)

    choose = request(browser, :get, "/select-role")
    [_all, assignment] = Regex.run(~r/<option value="([^"]+)"/, choose.resp_body)

    chosen =
      request(choose, :post, "/select-role", %{
        "_csrf_token" => csrf(choose),
        "role_assignment_id" => assignment
      })

    assert get_resp_header(chosen, "location") == ["/settings/users"]

    assert request(chosen, :get, "/settings") |> get_resp_header("location") == [
             "/settings/users"
           ]

    page = request(chosen, :get, "/settings/users")
    assert page.status == 200
    assert page.resp_body =~ ~s(id="settings-member-#{ctx.admin.id}")
    assert page.resp_body =~ ~s(id="settings-member-#{ctx.driver.id}")
    # Not offered to themselves; the server refuses it regardless.
    refute page.resp_body =~ ~s(<option value="#{ctx.admin.id}")
  end

  test "a grant made with a recent sign-in, once however often the form is sent", ctx do
    page = ctx.admin_user |> sign_in() |> request(:get, "/settings/users")
    form = grant_form(page, ctx.driver, ctx.definitions["DRIVER"])

    granted = request(page, :post, "/settings/users/assignments", form)
    assert granted.status == 303
    assert get_resp_header(granted, "location") == ["/settings/users"]

    again = request(page, :post, "/settings/users/assignments", form)
    assert again.status == 303
    assert [%{role_definition_id: role}] = held(ctx, ctx.driver)
    assert role == ctx.definitions["DRIVER"].id

    shown = request(granted, :get, "/settings/users")
    assert shown.resp_body =~ ~r/settings-member-#{ctx.driver.id}.*?Driver/s
  end

  test "an old sign-in is asked to sign in again, and nothing changes", ctx do
    long_ago = DateTime.add(DateTime.utc_now(), -10 * 60, :second)

    page =
      ctx.admin_user |> sign_in(authenticated_at: long_ago) |> request(:get, "/settings/users")

    refused =
      request(
        page,
        :post,
        "/settings/users/assignments",
        grant_form(page, ctx.driver, ctx.definitions["DRIVER"])
      )

    assert refused.status == 403
    assert refused.resp_body =~ "needs a recent sign-in"
    assert held(ctx, ctx.driver) == []
  end

  test "revoking ends the assignment shown on the page", ctx do
    assignment =
      Fixtures.assignment(ctx.tenant, ctx.carrier, ctx.driver, "DRIVER",
        definition: ctx.definitions["DRIVER"]
      )

    page = ctx.admin_user |> sign_in() |> request(:get, "/settings/users")

    revoked =
      request(
        page,
        :post,
        "/settings/users/assignments/#{assignment.id}/revoke",
        revoke_form(page, assignment)
      )

    assert revoked.status == 303
    assert held(ctx, ctx.driver) == []
  end

  test "a form without its idempotency key is refused, not run", ctx do
    page = ctx.admin_user |> sign_in() |> request(:get, "/settings/users")

    form =
      page |> grant_form(ctx.driver, ctx.definitions["DRIVER"]) |> Map.delete("idempotency_key")

    assert request(page, :post, "/settings/users/assignments", form).status == 400
    assert held(ctx, ctx.driver) == []
  end

  test "scenario 15: administration opens no operational page until another administrator grants one",
       ctx do
    admin_browser = sign_in(ctx.admin_user)
    assert request(admin_browser, :get, "/operations").status == 404
    assert request(admin_browser, :get, "/operations/participants/#{ctx.driver.id}").status == 404

    # Not by themselves.
    page = request(admin_browser, :get, "/settings/users")

    own =
      request(
        page,
        :post,
        "/settings/users/assignments",
        grant_form(page, ctx.admin, ctx.definitions["DISPATCHER"])
      )

    assert own.status == 403
    assert own.resp_body =~ "No one can grant themselves a role"

    # A second administrator grants it.
    %{user: other_user, participant: other} =
      Fixtures.person(ctx.tenant, ctx.carrier, display_name: "Bea")

    Fixtures.assignment(ctx.tenant, ctx.carrier, other, "ADMIN",
      definition: ctx.definitions["ADMIN"]
    )

    other_page = other_user |> sign_in() |> request(:get, "/settings/users")

    assert request(
             other_page,
             :post,
             "/settings/users/assignments",
             grant_form(other_page, ctx.admin, ctx.definitions["DISPATCHER"])
           ).status ==
             303

    # The first administrator now holds two assignments and chooses the operational one.
    choose = request(sign_in(ctx.admin_user), :get, "/select-role")

    [dispatcher] =
      for a <- held(ctx, ctx.admin),
          a.role_definition_id == ctx.definitions["DISPATCHER"].id,
          do: a.id

    chosen =
      request(choose, :post, "/select-role", %{
        "_csrf_token" => csrf(choose),
        "role_assignment_id" => dispatcher
      })

    assert request(chosen, :get, "/operations").status == 200
    assert request(chosen, :get, "/operations/participants/#{ctx.driver.id}").status == 200
    # And, as a dispatcher, no settings page.
    assert request(chosen, :get, "/settings/users").status == 404
  end
end
