defmodule DispatchWeb.MobileAcceptanceTest do
  @moduledoc "Actual Identity, enrolment ledger, Dispatch router, Ash and PostgreSQL acceptance."
  use ExUnit.Case, async: false
  use CoopSubstrate.LogCase
  import Plug.Conn
  import Plug.Test
  import CoopSubstrate.TaskTimingFixtures
  alias CoopSubstrate.{Crypto, Enrolments, Log}
  alias Dispatch.Support.Fixtures
  alias Dispatch.MobileDevices
  @moduletag :integration

  setup_all do
    {:ok, _} = Application.ensure_all_started(:coop_substrate)
    :ok
  end

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Dispatch.Repo)
    principal = BizKit.Identity.Principal.new_id()
    identity = %{issuer: "https://idp.test", subject: "mobile-person"}
    env = Application.get_all_env(:dispatch)
    identity_env = Application.get_all_env(:biz_kit_identity)

    on_exit(fn ->
      for {key, _} <- Application.get_all_env(:dispatch),
          do: Application.delete_env(:dispatch, key)

      Application.put_all_env(dispatch: env)

      for {key, _} <- Application.get_all_env(:biz_kit_identity),
          do: Application.delete_env(:biz_kit_identity, key)

      Application.put_all_env(biz_kit_identity: identity_env)
    end)

    Application.put_env(:biz_kit_identity, :bindings, [Map.put(identity, :principal, principal)])
    org = Fixtures.carrier()
    %{user: user, participant: participant} = Fixtures.person(org.id, org)
    role = Fixtures.assignment(org.id, org, participant, "DRIVER")
    scope = {"chapter-genesis", "tenant-1", "project-1"}
    Application.put_env(:dispatch, :mobile_enrolment_scopes, %{org.id => scope})
    Application.put_env(:dispatch, :mobile_principals, %{principal => user.oidc_subject})
    token = BizKit.Identity.Sessions.create(principal, identity)
    gov = new_member("governance")
    {:ok, _} = Log.append(declare_governance(gov))
    {public, seed} = Crypto.generate_keypair()
    key_id = MobileDevices.key_id(public)

    params = %{
      "key_id" => key_id,
      "public_key" => b64(public),
      "label" => "Android acceptance",
      "installation_id" => Ash.UUID.generate()
    }

    ctx = %{
      token: token,
      role: role,
      principal: principal,
      subject: user.oidc_subject,
      scope: scope,
      public: public,
      seed: seed,
      key_id: key_id,
      gov: gov,
      params: params
    }

    # Same routes the Android client calls, including proof of possession.
    challenge = call(ctx, :post, "/v1/me/device-enrolment", params) |> body(201)
    signature = Crypto.sign(Base.url_decode64!(challenge["statement"], padding: false), seed)

    request =
      call(ctx, :post, "/v1/me/device-enrolment/#{challenge["id"]}/proof", %{
        "signature" => b64(signature)
      })
      |> body(201)

    assert call(ctx, :post, "/v1/me/devices", params).status == 403
    {:ok, pending} = Enrolments.prepare_approval(request["code"], gov.signer.key_id)

    {:ok, _} =
      Enrolments.approve(
        request["code"],
        pending.id,
        Crypto.sign(pending.signing_bytes, gov.seed)
      )

    device = call(ctx, :post, "/v1/me/devices", params) |> body(201)
    Map.put(ctx, :device, device["device_id"])
  end

  defp b64(bytes), do: Base.url_encode64(bytes, padding: false)

  defp call(ctx, method, path, params, opts \\ []) do
    conn(method, path, Jason.encode!(params))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "BizKit " <> ctx.token)
    |> put_req_header("x-role-assignment-id", Keyword.get(opts, :role, ctx.role.id))
    |> then(fn c ->
      if params["event_id"], do: put_req_header(c, "idempotency-key", params["event_id"]), else: c
    end)
    |> Plug.RequestId.call(Plug.RequestId.init(assign_as: :correlation_id))
    |> Plug.Parsers.call(Plug.Parsers.init(parsers: [:json], pass: ["*/*"], json_decoder: Jason))
    |> DispatchWeb.Router.call(DispatchWeb.Router.init([]))
  end

  defp body(conn, status) do
    assert conn.status == status, conn.resp_body
    Jason.decode!(conn.resp_body)
  end

  defp declaration(ctx, sequence \\ 1) do
    params = %{
      "event_id" => Ash.UUIDv7.generate(),
      "status" => "EN_ROUTE_PICKUP",
      "occurred_at" => DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), -3600, :second)),
      "device_id" => ctx.device,
      "device_sequence" => sequence,
      "subject" => ctx.subject
    }

    {:ok, bytes} = MobileDevices.signing_bytes(params, ctx.role.id)
    Map.put(params, "device_signature", b64(Crypto.sign(bytes, ctx.seed)))
  end

  test "authenticated offline-created submission, byte-identical duplicate and conflict", ctx do
    queued = declaration(ctx)
    first = call(ctx, :post, "/v1/me/status-events", queued) |> body(201)
    assert first["event"]["role_assignment_id"] == ctx.role.id
    assert first["event"]["verification"] == "DEVICE_AUTHENTICATED"
    assert call(ctx, :post, "/v1/me/status-events", queued) |> body(201) == first
    # A changed declaration with a valid signature is a conflicting duplicate.
    altered = Map.delete(queued, "device_signature") |> Map.put("status", "AT_PICKUP")
    {:ok, bytes} = MobileDevices.signing_bytes(altered, ctx.role.id)
    altered = Map.put(altered, "device_signature", b64(Crypto.sign(bytes, ctx.seed)))
    assert call(ctx, :post, "/v1/me/status-events", altered).status == 409
  end

  test "wrong signatures, wrong device owner, missing signatures and stale sequences fail", ctx do
    queued = declaration(ctx)

    for altered <- [
          Map.delete(queued, "device_signature"),
          Map.put(queued, "device_signature", b64(<<0::512>>)),
          Map.put(queued, "subject", "somebody-else"),
          Map.put(queued, "device_id", Ash.UUID.generate())
        ] do
      assert call(ctx, :post, "/v1/me/status-events", altered) |> body(403) |> Map.fetch!("code") ==
               "DEVICE_REJECTED"
    end

    assert call(ctx, :post, "/v1/me/status-events", declaration(ctx, 2)).status == 201
    assert call(ctx, :post, "/v1/me/status-events", queued).status == 403
  end

  test "revocation refuses duplicates before the idempotency ledger", ctx do
    queued = declaration(ctx)
    assert call(ctx, :post, "/v1/me/status-events", queued).status == 201
    [grant] = CoopSubstrate.Devices.list(ctx.principal, ctx.scope)

    {:ok, pending} =
      CoopSubstrate.Devices.prepare_governance_revocation(grant.id, ctx.gov.signer.key_id)

    {:ok, _} =
      CoopSubstrate.Devices.revoke(
        grant.id,
        pending.id,
        Crypto.sign(pending.signing_bytes, ctx.gov.seed)
      )

    assert call(ctx, :post, "/v1/me/status-events", queued).status == 403
    assert call(ctx, :post, "/v1/me/devices", ctx.params).status == 403
  end

  test "logout and role revocation refuse replay; foreign assignment cannot select authority",
       ctx do
    queued = declaration(ctx)
    assert call(ctx, :post, "/v1/me/status-events", queued).status == 201

    assert call(ctx, :post, "/v1/me/status-events", queued, role: Ash.UUID.generate()).status ==
             403

    ctx.role
    |> Ash.Changeset.for_update(:revoke, %{})
    |> Ash.update!(authorize?: false, tenant: ctx.role.tenant_id)

    assert call(ctx, :post, "/v1/me/status-events", queued).status == 403
    BizKit.Identity.logout(ctx.token)
    assert call(ctx, :post, "/v1/me/status-events", queued).status == 401
  end

  test "unavailable ledger refuses enrolment and even a previously accepted replay", ctx do
    queued = declaration(ctx)
    accepted = call(ctx, :post, "/v1/me/status-events", queued) |> body(201)
    :ok = Application.stop(:coop_substrate)

    try do
      refute MobileDevices.available?()

      for {path, params} <- [
            {"/v1/me/devices", ctx.params},
            {"/v1/me/status-events", queued}
          ] do
        assert call(ctx, :post, path, params) |> body(503) |> Map.fetch!("code") ==
                 "DEVICE_UNAVAILABLE"
      end
    after
      {:ok, _} = Application.ensure_all_started(:coop_substrate)
    end

    assert MobileDevices.available?()
    assert call(ctx, :post, "/v1/me/status-events", queued) |> body(201) == accepted
  end

  test "an approved short key prefix does not approve a different public key", ctx do
    <<prefix::binary-size(4), _::binary>> = ctx.public
    collision = prefix <> :crypto.strong_rand_bytes(28)
    assert MobileDevices.key_id(collision) == ctx.key_id

    assert {:error, :device_rejected} =
             MobileDevices.approved(ctx.principal, ctx.scope, collision)
  end
end
