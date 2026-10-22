defmodule Dispatch.Identity.Tokens.BizKitSessionTest do
  @moduledoc """
  A biz-kit session as the `/v1` bearer token: the field app's sign-in reaches
  dispatch's Ash policies with the principal it resolved to, and loses access
  the moment biz-kit ends the session or its binding.
  """

  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias BizKit.Identity
  alias BizKit.Identity.{Principal, Sessions}
  alias Dispatch.Identity.Tokens.BizKitSession
  alias Dispatch.Support.Fixtures

  @identity %{issuer: "https://idp.test", subject: "alice"}

  setup do
    env = Application.get_all_env(:biz_kit_identity)
    identity = Application.get_env(:dispatch, :identity)

    on_exit(fn ->
      for {key, _value} <- Application.get_all_env(:biz_kit_identity),
          not Keyword.has_key?(env, key),
          do: Application.delete_env(:biz_kit_identity, key)

      Application.put_all_env(biz_kit_identity: env)
      Application.put_env(:dispatch, :identity, identity)
    end)

    principal = Principal.new_id()
    Application.put_env(:biz_kit_identity, :bindings, [Map.put(@identity, :principal, principal)])
    %{principal: principal, session: Sessions.create(principal, @identity)}
  end

  describe "verify/1" do
    test "a live session yields its principal as the subject", ctx do
      assert {:ok, %{subject: subject, issuer: "biz-kit", expires_at: %DateTime{}}} =
               BizKitSession.verify(ctx.session)

      assert subject == ctx.principal
    end

    test "it says when the person signed in, for a step-up to ask", ctx do
      {:ok, %{authenticated_at: signed_in}} = BizKit.Identity.session(ctx.session)

      assert {:ok, %{authenticated_at: at}} = BizKitSession.verify(ctx.session)
      assert DateTime.to_unix(at, :millisecond) == signed_in
    end

    test "logout, revocation and unbinding each end it at once", ctx do
      Identity.logout(ctx.session)
      assert {:error, :invalid_token} = BizKitSession.verify(ctx.session)

      session = Sessions.create(ctx.principal, @identity)
      Identity.revoke_principal(ctx.principal)
      assert {:error, :invalid_token} = BizKitSession.verify(session)

      session = Sessions.create(ctx.principal, @identity)
      Application.put_env(:biz_kit_identity, :bindings, [])
      assert {:error, :invalid_token} = BizKitSession.verify(session)
    end

    test "a native app's session has no expiry, and still ends at logout", ctx do
      session = Sessions.create_native(ctx.principal, @identity)

      assert {:ok, %{subject: subject, expires_at: nil}} = BizKitSession.verify(session)
      assert subject == ctx.principal

      Identity.logout(session)
      assert {:error, :invalid_token} = BizKitSession.verify(session)
    end

    test "an expired session is reported as expired" do
      Application.put_env(:biz_kit_identity, :session_ttl_ms, -1)
      principal = Principal.new_id()

      Application.put_env(:biz_kit_identity, :bindings, [
        %{issuer: "https://idp.test", subject: "bob", principal: principal}
      ])

      session = Sessions.create(principal, %{issuer: "https://idp.test", subject: "bob"})
      assert {:error, :expired} = BizKitSession.verify(session)
    end

    test "anything else is not a token" do
      for token <- ["", "made-up", nil, 42] do
        assert {:error, :invalid_token} = BizKitSession.verify(token)
      end
    end
  end

  describe "the /v1 API with a biz-kit session" do
    @describetag :integration

    setup ctx do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Dispatch.Repo)

      Application.put_env(
        :dispatch,
        :identity,
        Keyword.put(Application.get_env(:dispatch, :identity), :token_verifier, BizKitSession)
      )

      org = Fixtures.carrier()
      %{participant: driver} = Fixtures.person(org.id, org, oidc_subject: ctx.principal)
      Fixtures.assignment(org.id, org, driver, "DRIVER")
      :ok
    end

    defp get_v1(path, token) do
      :get
      |> conn(path)
      |> Plug.RequestId.call(Plug.RequestId.init(assign_as: :correlation_id))
      |> put_req_header("authorization", "Bearer " <> token)
      |> DispatchWeb.Router.call(DispatchWeb.Router.init([]))
    end

    test "reaches the principal's own dispatch user, and stops when the session ends", ctx do
      conn = get_v1("/v1/me/role-assignments", ctx.session)
      assert conn.status == 200
      assert [%{"label" => "Driver"}] = Jason.decode!(conn.resp_body)["role_assignments"]

      Identity.logout(ctx.session)

      refused = get_v1("/v1/me/role-assignments", ctx.session)
      assert refused.status == 401
      assert Jason.decode!(refused.resp_body)["code"] == "UNAUTHENTICATED"
    end
  end
end
