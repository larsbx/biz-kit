defmodule DispatchWeb.MobileSessionTest do
  use ExUnit.Case, async: false
  import Plug.Conn
  import Plug.Test
  alias BizKit.Identity

  defmodule Provider do
    @behaviour BizKit.Identity.Provider
    @spec authorize_url(keyword(), String.t(), String.t()) :: String.t()
    def authorize_url(_, state, callback),
      do:
        "https://idp.test/authorize?" <> URI.encode_query(%{state: state, redirect_uri: callback})

    @spec authenticate(keyword(), String.t(), String.t()) :: {:ok, map()} | {:error, atom()}
    def authenticate(_, "good", _), do: {:ok, %{issuer: "https://idp.test", subject: "person"}}
    def authenticate(_, _, _), do: {:error, :rejected}
  end

  setup do
    env =
      for app <- [:dispatch, :biz_kit_identity],
          into: %{},
          do: {app, Application.get_all_env(app)}

    on_exit(fn ->
      for {app, values} <- env do
        for {key, _} <- Application.get_all_env(app), do: Application.delete_env(app, key)
        Application.put_all_env([{app, values}])
      end
    end)

    principal = BizKit.Identity.Principal.new_id()
    Application.put_env(:biz_kit_identity, :providers, %{"test" => {Provider, []}})

    Application.put_env(:biz_kit_identity, :native_redirect_uris, ["com.dispatch.driver://signin"])

    Application.put_env(:biz_kit_identity, :bindings, [
      %{issuer: "https://idp.test", subject: "person", principal: principal}
    ])

    Application.put_env(:dispatch, :native_identity,
      provider: "test",
      public_url: "https://dispatch.test",
      redirect_uri: "com.dispatch.driver://signin"
    )

    Application.put_env(:dispatch, :mobile_principals, %{principal => "explicit-account-link"})
    Application.put_env(:dispatch, :native_secure_cookies, false)
    :ok
  end

  defp call(method, path, params \\ %{}, headers \\ []) do
    conn(method, path, Jason.encode!(params))
    |> put_req_header("content-type", "application/json")
    |> then(fn conn ->
      Enum.reduce(headers, conn, fn {k, v}, c -> put_req_header(c, k, v) end)
    end)
    |> Plug.Parsers.call(Plug.Parsers.init(parsers: [:json], pass: ["*/*"], json_decoder: Jason))
    |> DispatchWeb.Router.call(DispatchWeb.Router.init([]))
  end

  defp flow do
    verifier = String.duplicate("v", 43)
    challenge = Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false)

    start =
      call(:post, "/v1/mobile/authorize", %{
        "code_challenge" => challenge,
        "state" => String.duplicate("s", 43)
      })

    assert start.status == 200
    url = Jason.decode!(start.resp_body)["authorization_url"] |> URI.parse()
    id = URI.decode_query(url.query)["id"]
    login = call(:get, "/v1/mobile/login?" <> url.query)
    assert login.status == 302
    cookie = "dispatch_native_state=" <> id
    %{id: id, cookie: cookie, verifier: verifier}
  end

  test "browser state cookie is mandatory and the callback never carries a session" do
    f = flow()
    callback = "/v1/mobile/callback?" <> URI.encode_query(%{state: f.id, code: "good"})
    assert call(:get, callback).status == 401
    assert call(:get, callback, %{}, [{"cookie", "dispatch_native_state=forged"}]).status == 401
    response = call(:get, callback, %{}, [{"cookie", f.cookie}])
    assert response.status == 302
    [location] = get_resp_header(response, "location")
    refute location =~ "access_token"
    params = URI.parse(location).query |> URI.decode_query()
    assert params["state"] == String.duplicate("s", 43)

    exchanged =
      call(:post, "/v1/mobile/token", %{"code" => params["code"], "code_verifier" => f.verifier})

    assert exchanged.status == 200
    session = Jason.decode!(exchanged.resp_body)
    assert session["subject"] == "explicit-account-link"
    assert {:ok, _} = Identity.session(session["access_token"])

    assert call(:post, "/v1/mobile/token", %{
             "code" => params["code"],
             "code_verifier" => f.verifier
           }).status == 401

    assert call(:delete, "/v1/mobile/session", %{}, [
             {"authorization", "BizKit " <> session["access_token"]}
           ]).status == 204

    assert {:error, _} = Identity.session(session["access_token"])
  end

  test "caller URLs cannot choose the provider redirect and malformed callbacks fail closed" do
    f = flow()

    response =
      call(
        :get,
        "/v1/mobile/login?" <> URI.encode_query(%{id: f.id, url: "https://attacker.invalid"})
      )

    [location] = get_resp_header(response, "location")
    assert location =~ "https://idp.test/authorize"
    refute location =~ "attacker.invalid"
    assert call(:get, "/v1/mobile/callback?state[wrong]=value&code=good").status == 401
    assert call(:post, "/v1/mobile/token", %{"code" => nil, "code_verifier" => nil}).status == 401
  end
end

