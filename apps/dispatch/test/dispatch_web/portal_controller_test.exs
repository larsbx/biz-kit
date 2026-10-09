defmodule DispatchWeb.PortalControllerTest do
  @moduledoc """
  The role-scoped portal, end to end: session, role selection, rendered page.

  The view-model tests prove a leak cannot be *constructed*. These prove it does
  not reach a person, which is a different claim — a page can leak through a
  layout, an error message, or a header without the view model carrying
  anything. So these assert over the rendered bytes.
  """

  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias Dispatch.Support.Fixtures
  alias Dispatch.Support.Tokens.StaticVerifier
  alias DispatchWeb.Plugs.PortalSession

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
    shipper_org = Fixtures.organization(tenant, :SHIPPER)

    load = Fixtures.load(tenant, carrier, agreed_rate_minor: 917_500, currency: "USD")
    pickup = Fixtures.stop(tenant, load, :PICKUP, sequence: 1, address_text: "Dock 4, Barking")
    delivery = Fixtures.stop(tenant, load, :DELIVERY, sequence: 2, address_text: "Bay 9, Leeds")

    Fixtures.stop_party(tenant, pickup, shipper_org, :SHIPPER)

    %{user: shipper_user, participant: shipper} = Fixtures.person(tenant, shipper_org)
    assignment = Fixtures.assignment(tenant, shipper_org, shipper, "SHIPPER", scope_id: pickup.id)
    %{participant: carrier_side} = Fixtures.person(tenant, carrier, user: shipper_user)

    %{
      tenant: tenant,
      carrier: carrier,
      shipper_org: shipper_org,
      load: load,
      pickup: pickup,
      delivery: delivery,
      shipper_user: shipper_user,
      shipper_participant: carrier_side,
      assignment: assignment
    }
  end

  # The endpoint normally supplies this; these tests drive the router directly so
  # they can set session contents without signing a cookie for every case.
  defp with_secret(conn) do
    put_in(
      conn.secret_key_base,
      Application.get_env(:dispatch, DispatchWeb.Endpoint)[:secret_key_base]
    )
  end

  defp get(path, opts \\ []) do
    :get
    |> conn(path)
    |> with_secret()
    |> Plug.RequestId.call(Plug.RequestId.init(assign_as: :correlation_id))
    |> Plug.Session.call(@session)
    |> fetch_session()
    |> then(fn conn ->
      case Keyword.get(opts, :session) do
        nil -> conn
        entries -> Enum.reduce(entries, conn, fn {k, v}, acc -> put_session(acc, k, v) end)
      end
    end)
    |> DispatchWeb.Router.call(@opts)
  end

  defp signed_in(ctx, overrides \\ []) do
    [
      session: [
        {PortalSession.subject_key(),
         Keyword.get(overrides, :subject, ctx.shipper_user.oidc_subject)},
        {PortalSession.assignment_key(), Keyword.get(overrides, :assignment, ctx.assignment.id)}
      ]
    ]
  end

  describe "signing in" do
    test "an anonymous request is sent to sign in, not shown the page", ctx do
      conn = get("/partner/stops/#{ctx.pickup.id}")

      assert conn.status == 302
      assert get_resp_header(conn, "location") == ["/login"]
      refute conn.resp_body =~ ctx.pickup.address_text
    end

    test "a session naming an assignment the principal does not hold is signed out", ctx do
      elsewhere = Fixtures.carrier()
      %{participant: stranger} = Fixtures.person(elsewhere.id, elsewhere)
      theirs = Fixtures.assignment(elsewhere.id, elsewhere, stranger, "DISPATCHER")

      # Section 24.6: the session value selects authority context, never grants
      # it. A cookie naming somebody else's assignment must select nothing.
      conn = get("/partner/stops/#{ctx.pickup.id}", signed_in(ctx, assignment: theirs.id))

      assert conn.status == 302
      assert get_resp_header(conn, "location") == ["/login"]
    end
  end

  describe "a principal holding several assignments" do
    setup ctx do
      # A second assignment in the same tenant, so the session cannot resolve
      # one without being told which — the exact state the switcher exists for.
      second = Fixtures.assignment(ctx.tenant, ctx.carrier, ctx.shipper_participant, "DISPATCHER")
      Map.put(ctx, :second_assignment, second)
    end

    test "reaches the role switcher instead of looping", ctx do
      # `/select-role` must be reachable *without* a resolved actor: it is how
      # one is chosen. Guarding it with the plug that demands one sends the
      # multi-assignment user round in circles — and only them, which is why a
      # single-assignment test suite never sees it.
      conn =
        get("/select-role",
          session: [{PortalSession.subject_key(), ctx.shipper_user.oidc_subject}]
        )

      assert conn.status == 200
      assert conn.resp_body =~ "role_assignment_id"
    end

    test "a page request with no selection redirects once, to a page that renders", ctx do
      conn =
        get("/partner/stops/#{ctx.pickup.id}",
          session: [{PortalSession.subject_key(), ctx.shipper_user.oidc_subject}]
        )

      assert conn.status == 302
      assert [target] = get_resp_header(conn, "location")

      landed =
        get(target, session: [{PortalSession.subject_key(), ctx.shipper_user.oidc_subject}])

      # The redirect target must not redirect again to itself.
      assert landed.status == 200
    end
  end

  describe "signing in over an existing session" do
    test "does not carry the previous selection into the new subject's session", ctx do
      %{user: other_user, participant: other} = Fixtures.person(ctx.tenant, ctx.carrier)
      Fixtures.assignment(ctx.tenant, ctx.carrier, other, "DISPATCHER")

      form =
        get("/login",
          session: [
            {PortalSession.subject_key(), ctx.shipper_user.oidc_subject},
            {PortalSession.assignment_key(), ctx.assignment.id}
          ]
        )

      [_all, csrf] = Regex.run(~r/name="_csrf_token" value="([^"]+)"/, form.resp_body)

      # A browser that already selected a role signs in as somebody else.
      # `renew: true` renews the session id and keeps its contents, so the
      # previous user's assignment would still be sitting there — and the new
      # user's perfectly valid sign-in would present it, fail, and look broken.
      signed_in =
        post_form(form, "/session", %{
          "token" => StaticVerifier.token_for(other_user.oidc_subject),
          "_csrf_token" => csrf
        })

      assert signed_in.status == 302
      assert get_session(signed_in, PortalSession.subject_key()) == other_user.oidc_subject
      refute get_session(signed_in, PortalSession.assignment_key())
    end
  end

  describe "the partner stop page" do
    test "renders the stop the shipper is party to", ctx do
      conn = get("/partner/stops/#{ctx.pickup.id}", signed_in(ctx))

      assert conn.status == 200
      assert conn.resp_body =~ "Dock 4, Barking"
      assert conn.resp_body =~ "partner-stop-page"
    end

    test "never renders the rate, the other stop, or the commodity", ctx do
      conn = get("/partner/stops/#{ctx.pickup.id}", signed_in(ctx))

      # Over the bytes a browser receives, not over a struct. A layout or an
      # error template could reintroduce any of these without the view model
      # changing at all.
      refute conn.resp_body =~ "917500"
      refute conn.resp_body =~ "9175"
      refute conn.resp_body =~ "USD"
      refute conn.resp_body =~ "Bay 9, Leeds"
      refute conn.resp_body =~ ctx.delivery.id
    end

    test "a stop the shipper is not party to is a 404 that admits nothing", ctx do
      unrelated = get("/partner/stops/#{ctx.delivery.id}", signed_in(ctx))
      absent = get("/partner/stops/#{Ash.UUID.generate()}", signed_in(ctx))

      assert unrelated.status == 404
      assert absent.status == 404
      # Acceptance criterion 19: identical responses, so the page cannot be used
      # to ask whether a stop exists.
      assert unrelated.resp_body == absent.resp_body
      refute unrelated.resp_body =~ "Bay 9, Leeds"
    end

    test "ending the party relationship closes the page immediately", ctx do
      assert get("/partner/stops/#{ctx.pickup.id}", signed_in(ctx)).status == 200

      Fixtures.end_stop_party(ctx.tenant, ctx.pickup, ctx.shipper_org)

      assert get("/partner/stops/#{ctx.pickup.id}", signed_in(ctx)).status == 404
    end

    test "revoking the role assignment signs the session out", ctx do
      assert get("/partner/stops/#{ctx.pickup.id}", signed_in(ctx)).status == 200

      Fixtures.revoke(ctx.tenant, ctx.assignment)

      conn = get("/partner/stops/#{ctx.pickup.id}", signed_in(ctx))
      assert conn.status == 302
      assert get_resp_header(conn, "location") == ["/login"]
    end
  end

  describe "Section 26.1: the response's own headers" do
    test "forbid inline script, framing, and caching", ctx do
      conn = get("/partner/stops/#{ctx.pickup.id}", signed_in(ctx))

      [csp] = get_resp_header(conn, "content-security-policy")

      assert csp =~ "script-src 'self'"
      # Section 26.1 prohibits inline scripts outright; a CSP that allowed them
      # would make the prohibition unenforceable whatever the templates do.
      refute csp =~ "unsafe-inline"
      refute csp =~ "unsafe-eval"
      assert csp =~ "frame-ancestors 'none'"

      assert get_resp_header(conn, "cache-control") == ["no-store"]
      assert get_resp_header(conn, "referrer-policy") == ["no-referrer"]
      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]

      # Must agree with `frame-ancestors 'none'` above: a browser that honours
      # only one of them should reach the same conclusion either way.
      assert get_resp_header(conn, "x-frame-options") == ["DENY"]
    end

    test "reference only static assets that exist", ctx do
      conn = get("/partner/stops/#{ctx.pickup.id}", signed_in(ctx))

      referenced =
        Regex.scan(~r/(?:src|href)="(\/static\/[^"]+)"/, conn.resp_body)
        |> Enum.map(fn [_all, path] -> path end)

      assert referenced != []

      # A stylesheet or bundle that 404s degrades the page silently — the
      # server still returns 200 and the CSP still looks right. Only the
      # filesystem knows, so ask it.
      for path <- referenced do
        on_disk = Path.join("priv/static", String.replace_prefix(path, "/static/", ""))
        assert File.exists?(Application.app_dir(:dispatch, on_disk)), "missing asset: #{path}"
      end
    end

    test "load the Datastar bundle from this origin, never a CDN", ctx do
      conn = get("/partner/stops/#{ctx.pickup.id}", signed_in(ctx))

      assert conn.resp_body =~ ~s(src="/static/vendor/datastar.js")
      refute conn.resp_body =~ "cdn."
      # Section 26.1 forbids general application JavaScript; an inline script
      # tag is how that erodes first.
      refute conn.resp_body =~ "<script>"
    end
  end

  describe "acceptance criterion 14: an administrator sees no operational page" do
    test "an ADMIN-only principal gets a 404 on a participant page", ctx do
      %{user: admin_user, participant: admin} = Fixtures.person(ctx.tenant, ctx.carrier)
      admin_assignment = Fixtures.assignment(ctx.tenant, ctx.carrier, admin, "ADMIN")
      %{participant: driver} = Fixtures.person(ctx.tenant, ctx.carrier)

      conn =
        get("/operations/participants/#{driver.id}",
          session: [
            {PortalSession.subject_key(), admin_user.oidc_subject},
            {PortalSession.assignment_key(), admin_assignment.id}
          ]
        )

      assert conn.status == 404
      refute conn.resp_body =~ driver.public_name
    end
  end

  describe "Section 4.3: the DRIVER compatibility projection" do
    test "renders the same page as the canonical route", ctx do
      %{user: dispatcher_user, participant: dispatcher} = Fixtures.person(ctx.tenant, ctx.carrier)
      dispatch_assignment = Fixtures.assignment(ctx.tenant, ctx.carrier, dispatcher, "DISPATCHER")
      %{participant: driver} = Fixtures.person(ctx.tenant, ctx.carrier)

      session = [
        session: [
          {PortalSession.subject_key(), dispatcher_user.oidc_subject},
          {PortalSession.assignment_key(), dispatch_assignment.id}
        ]
      ]

      canonical = get("/operations/participants/#{driver.id}", session)
      compatibility = get("/operations/drivers/#{driver.id}", session)

      assert canonical.status == 200
      assert compatibility.status == 200
      # One function body, so the projection cannot drift from the canonical
      # route — Section 24.3 asks for exactly that of the compatibility routes.
      assert canonical.resp_body == compatibility.resp_body
    end
  end

  describe "signing in with a token" do
    test "a verified token opens a session; an unverifiable one does not", ctx do
      # Section 26.4 requires CSRF protection on action forms, so the form is
      # fetched and its token replayed — which is also the only way to prove the
      # rendered form actually carries one.
      form = get("/login")
      [_all, csrf] = Regex.run(~r/name="_csrf_token" value="([^"]+)"/, form.resp_body)

      conn =
        post_form(form, "/session", %{
          "token" => StaticVerifier.token_for(ctx.shipper_user.oidc_subject),
          "_csrf_token" => csrf
        })

      assert conn.status == 302
      assert get_session(conn, PortalSession.subject_key()) == ctx.shipper_user.oidc_subject

      rejected = post_form(form, "/session", %{"token" => "not-a-token", "_csrf_token" => csrf})

      assert rejected.status == 401
      refute get_session(rejected, PortalSession.subject_key())
    end

    test "a form post without a CSRF token is refused", ctx do
      # Wrapped by the router, which is how a browser would meet it too.
      assert_raise Plug.Conn.WrapperError, ~r/InvalidCSRFTokenError/, fn ->
        :post
        |> conn("/session", %{"token" => StaticVerifier.token_for(ctx.shipper_user.oidc_subject)})
        |> with_secret()
        |> Plug.Session.call(@session)
        |> fetch_session()
        |> DispatchWeb.Router.call(@opts)
      end
    end
  end

  # Replays the session cookie from `source`, so the CSRF token taken from its
  # body is the one this session is bound to.
  defp post_form(source, path, params) do
    :post
    |> conn(path, params)
    |> with_secret()
    |> recycle_cookies(source)
    |> Plug.Session.call(@session)
    |> fetch_session()
    |> DispatchWeb.Router.call(@opts)
  end
end
