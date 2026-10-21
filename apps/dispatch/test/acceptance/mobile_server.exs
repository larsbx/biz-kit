# Test-only actual backend for d-patch's Robolectric/Room/HTTP acceptance lane.
# Never compiled into a release. Use an isolated disposable test database.
if Mix.env() != :test, do: raise("acceptance server is test-only")
secret = System.fetch_env!("DISPATCH_E2E_CONTROL_KEY")
port = System.get_env("DISPATCH_E2E_PORT", "4005") |> String.to_integer()
base = "http://127.0.0.1:#{port}"
{:ok, _} = Application.ensure_all_started(:coop_substrate)
CoopSubstrate.LogCase.truncate_store!()
CoopSubstrate.LogCase.restart_log()
Ecto.Adapters.SQL.Sandbox.mode(Dispatch.Repo, :auto)

defmodule DispatchAcceptance.Provider do
  @behaviour BizKit.Identity.Provider
  @spec authorize_url(keyword(), String.t(), String.t()) :: String.t()
  def authorize_url(config, state, callback),
    do:
      config[:base] <>
        "/__acceptance__/provider?" <> URI.encode_query(%{state: state, redirect_uri: callback})

  @spec authenticate(keyword(), String.t(), String.t()) :: {:ok, map()} | {:error, atom()}

  def authenticate(_, "acceptance-person", _),
    do: {:ok, %{issuer: "https://acceptance.invalid", subject: "person"}}

  def authenticate(_, _, _), do: {:error, :rejected}
end

principal = BizKit.Identity.Principal.new_id()

Application.put_env(:biz_kit_identity, :providers, %{
  "acceptance" => {DispatchAcceptance.Provider, base: base}
})

Application.put_env(:biz_kit_identity, :bindings, [
  %{issuer: "https://acceptance.invalid", subject: "person", principal: principal}
])

Application.put_env(:dispatch, :native_identity,
  provider: "acceptance",
  public_url: base,
  redirect_uri: "com.dispatch.driver://signin"
)

Application.put_env(:dispatch, :native_secure_cookies, false)
org = Dispatch.Support.Fixtures.carrier()
%{user: user, participant: participant} = Dispatch.Support.Fixtures.person(org.id, org)
role = Dispatch.Support.Fixtures.assignment(org.id, org, participant, "DRIVER")
scope = {"chapter-genesis", "tenant-1", "project-1"}
Application.put_env(:dispatch, :mobile_principals, %{principal => user.oidc_subject})
Application.put_env(:dispatch, :mobile_enrolment_scopes, %{org.id => scope})
gov = CoopSubstrate.LogCase.new_member("governance")
{:ok, _} = CoopSubstrate.Log.append(CoopSubstrate.TaskTimingFixtures.declare_governance(gov))

Application.put_env(:dispatch, :acceptance_context, %{
  secret: secret,
  role: role,
  principal: principal,
  subject: user.oidc_subject,
  scope: scope,
  gov: gov
})

defmodule DispatchAcceptance.Router do
  import Plug.Conn
  @spec init(term()) :: term()
  def init(opts), do: opts

  @spec call(Plug.Conn.t(), term()) :: Plug.Conn.t()

  def call(conn, _) do
    conn = fetch_query_params(conn)
    ctx = Application.fetch_env!(:dispatch, :acceptance_context)

    case {conn.method, conn.path_info} do
      {"GET", ["__acceptance__", "provider"]} ->
        # Fixed provider endpoint supplied only by this test fixture.
        callback =
          Application.fetch_env!(:dispatch, :native_identity)[:public_url] <>
            "/v1/mobile/callback"

        conn
        |> put_resp_header(
          "location",
          callback <>
            "?" <>
            URI.encode_query(%{state: conn.query_params["state"], code: "acceptance-person"})
        )
        |> send_resp(302, "")

      {_, ["__acceptance__", action]} ->
        if get_req_header(conn, "x-acceptance-key") == [ctx.secret] do
          control(conn, action, ctx)
        else
          send_resp(conn, 403, "")
        end

      _ ->
        DispatchWeb.Endpoint.call(conn, DispatchWeb.Endpoint.init([]))
    end
  end

  defp control(conn, "context", ctx),
    do: json(conn, %{role_id: ctx.role.id, subject: ctx.subject})

  defp control(conn, "approve", ctx) do
    {:ok, raw, conn} = read_body(conn)
    %{"code" => code} = Jason.decode!(raw)
    {:ok, pending} = CoopSubstrate.Enrolments.prepare_approval(code, ctx.gov.signer.key_id)

    {:ok, _} =
      CoopSubstrate.Enrolments.approve(
        code,
        pending.id,
        CoopSubstrate.Crypto.sign(pending.signing_bytes, ctx.gov.seed)
      )

    json(conn, %{ok: true})
  end

  defp control(conn, "revoke-key", ctx) do
    [device | _] = CoopSubstrate.Devices.list(ctx.principal, ctx.scope)

    {:ok, pending} =
      CoopSubstrate.Devices.prepare_governance_revocation(device.id, ctx.gov.signer.key_id)

    {:ok, _} =
      CoopSubstrate.Devices.revoke(
        device.id,
        pending.id,
        CoopSubstrate.Crypto.sign(pending.signing_bytes, ctx.gov.seed)
      )

    json(conn, %{ok: true})
  end

  defp control(conn, "revoke-role", ctx) do
    ctx.role
    |> Ash.Changeset.for_update(:revoke, %{})
    |> Ash.update!(authorize?: false, tenant: ctx.role.tenant_id)

    json(conn, %{ok: true})
  end

  defp control(conn, "event-count", ctx) do
    result =
      Ecto.Adapters.SQL.query!(
        Dispatch.Repo,
        "SELECT count(*) FROM participant_status_events WHERE participant_id = $1",
        [Ecto.UUID.dump!(ctx.role.principal_id)]
      )

    [[count]] = result.rows
    json(conn, %{count: count})
  end

  defp control(conn, _, _), do: send_resp(conn, 404, "")

  defp json(conn, value),
    do: conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(value))
end

{:ok, _} = Bandit.start_link(plug: DispatchAcceptance.Router, port: port, ip: {127, 0, 0, 1})
IO.puts("SLICE1_ACCEPTANCE_READY")
