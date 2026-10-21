defmodule DispatchWeb.DeviceControllerTest do
  @moduledoc """
  `POST /v1/me/devices` (Section 23.1; docs/architecture/2026-10-21-device-keys.md):
  the field app registers its installation key itself, proving it holds it,
  and its declarations then carry that key's signature.
  """

  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias CoopSubstrate.{Canonical, Crypto}
  alias Dispatch.Accounts.Device
  alias Dispatch.Support.Fixtures
  alias Dispatch.Support.Tokens.StaticVerifier

  require Ash.Query

  @moduletag :integration

  @opts DispatchWeb.Router.init([])

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Dispatch.Repo)

    org = Fixtures.carrier()
    %{user: user, participant: driver} = Fixtures.person(org.id, org)
    assignment = Fixtures.assignment(org.id, org, driver, "DRIVER")

    %{
      org: org,
      tenant: org.id,
      driver: driver,
      assignment: assignment,
      token: StaticVerifier.token_for(user.oidc_subject)
    }
  end

  defp post(path, body, token, headers \\ []) do
    :post
    |> conn(path, Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer " <> token)
    |> then(fn conn ->
      Enum.reduce(headers, conn, fn {k, v}, c -> put_req_header(c, k, v) end)
    end)
    |> Plug.Parsers.call(Plug.Parsers.init(parsers: [:json], pass: ["*/*"], json_decoder: Jason))
    |> DispatchWeb.Router.call(@opts)
  end

  defp b64(bytes), do: Base.url_encode64(bytes, padding: false)

  # The statement as documented, built here rather than by the module under test.
  defp statement(ctx, installation_id, public_key, overrides \\ %{}) do
    Canonical.encode!(
      Map.merge(
        %{
          "schema" => "DispatchDeviceRegistrationV1",
          "tenant_id" => ctx.tenant,
          "participant_id" => ctx.driver.id,
          "installation_id" => installation_id,
          "public_key" => {:bytes, public_key}
        },
        overrides
      )
    )
  end

  defp registration(ctx, installation_id, {public_key, seed}, overrides \\ %{}) do
    %{
      "installation_id" => installation_id,
      "public_key" => b64(public_key),
      "proof" => b64(Crypto.sign(statement(ctx, installation_id, public_key, overrides), seed))
    }
  end

  defp devices(ctx) do
    Device
    |> Ash.Query.filter(participant_id == ^ctx.driver.id)
    |> Ash.read!(authorize?: false, tenant: ctx.tenant)
  end

  test "a device proving its key is registered to the caller, once", ctx do
    keys = Crypto.generate_keypair()
    body = registration(ctx, "install-1", keys)

    first = post("/v1/me/devices", body, ctx.token)
    assert first.status == 201
    assert %{"device_id" => id, "installation_id" => "install-1"} = Jason.decode!(first.resp_body)

    again = post("/v1/me/devices", body, ctx.token)
    assert again.status == 200
    assert Jason.decode!(again.resp_body)["device_id"] == id

    assert [%Device{id: ^id, status: :ACTIVE, public_key: key}] = devices(ctx)
    assert key == b64(elem(keys, 0))
  end

  test "a proof by another key, or over another statement, is refused", ctx do
    {public_key, _seed} = Crypto.generate_keypair()
    {_other, other_seed} = Crypto.generate_keypair()

    forged = registration(ctx, "install-1", {public_key, other_seed})
    assert %{status: 422} = conn = post("/v1/me/devices", forged, ctx.token)
    assert Jason.decode!(conn.resp_body)["code"] == "PROOF_INVALID"

    # Signed for someone else: the server binds the statement to the caller.
    %{participant: other} = Fixtures.person(ctx.tenant, ctx.org)

    elsewhere =
      registration(ctx, "install-1", Crypto.generate_keypair(), %{"participant_id" => other.id})

    assert post("/v1/me/devices", elsewhere, ctx.token).status == 422

    # A statement with a `type` is not this one.
    typed = registration(ctx, "install-1", Crypto.generate_keypair(), %{"type" => "x"})
    assert post("/v1/me/devices", typed, ctx.token).status == 422

    assert devices(ctx) == []
  end

  test "an installation keeps its key: another key, or another tenant, is a conflict", ctx do
    assert post(
             "/v1/me/devices",
             registration(ctx, "install-1", Crypto.generate_keypair()),
             ctx.token
           ).status ==
             201

    conn =
      post("/v1/me/devices", registration(ctx, "install-1", Crypto.generate_keypair()), ctx.token)

    assert conn.status == 409
    assert Jason.decode!(conn.resp_body)["code"] == "INSTALLATION_CONFLICT"

    elsewhere = Fixtures.carrier()
    %{participant: stranger} = Fixtures.person(elsewhere.id, elsewhere)
    theirs = Fixtures.device(elsewhere.id, stranger)

    taken = registration(ctx, theirs.installation_id, Crypto.generate_keypair())
    assert post("/v1/me/devices", taken, ctx.token).status == 409
  end

  test "a registration honours Idempotency-Key, like every mutation (Section 24)", ctx do
    key = [{"idempotency-key", "key-" <> Ash.UUID.generate()}]
    body = registration(ctx, "install-1", Crypto.generate_keypair())

    first = post("/v1/me/devices", body, ctx.token, key)
    replay = post("/v1/me/devices", body, ctx.token, key)
    assert {first.status, replay.status} == {201, 201}
    assert Jason.decode!(replay.resp_body) == Jason.decode!(first.resp_body)

    reused =
      post(
        "/v1/me/devices",
        registration(ctx, "install-2", Crypto.generate_keypair()),
        ctx.token,
        key
      )

    assert reused.status == 409
    assert Jason.decode!(reused.resp_body)["code"] == "IDEMPOTENCY_KEY_REUSED"
    assert length(devices(ctx)) == 1
  end

  test "under an Idempotency-Key, an installation taken in another tenant is still a conflict",
       ctx do
    elsewhere = Fixtures.carrier()
    %{participant: stranger} = Fixtures.person(elsewhere.id, elsewhere)
    theirs = Fixtures.device(elsewhere.id, stranger)

    conn =
      post(
        "/v1/me/devices",
        registration(ctx, theirs.installation_id, Crypto.generate_keypair()),
        ctx.token,
        [{"idempotency-key", "key-" <> Ash.UUID.generate()}]
      )

    assert conn.status == 409
    assert Jason.decode!(conn.resp_body)["code"] == "INSTALLATION_CONFLICT"
  end

  test "malformed registrations are refused", ctx do
    {public_key, seed} = keys = Crypto.generate_keypair()
    valid = registration(ctx, "install-1", keys)

    for body <- [
          %{valid | "public_key" => b64(binary_part(public_key, 0, 31))},
          %{valid | "proof" => "not base64!"},
          %{valid | "installation_id" => ""},
          Map.delete(valid, "proof"),
          %{
            valid
            | "installation_id" => String.duplicate("i", 201),
              "proof" =>
                b64(Crypto.sign(statement(ctx, String.duplicate("i", 201), public_key), seed))
          }
        ] do
      assert post("/v1/me/devices", body, ctx.token).status == 422
    end
  end

  test "what was signed must name the device the declaration is recorded under", ctx do
    {:ok, actor} = Dispatch.Access.Actor.from_assignment(ctx.assignment)
    {mine, _seed} = Fixtures.keyed_device(ctx.tenant, ctx.driver)
    {other, other_seed} = Fixtures.keyed_device(ctx.tenant, ctx.driver)

    fields =
      Fixtures.signed(
        %{
          "status" => "AT_PICKUP",
          "occurred_at" => "2026-10-21T10:00:00Z",
          "device_id" => other.id
        },
        other_seed
      )

    assert {:error, :device_signature_invalid} =
             Dispatch.Operations.Declarations.declare(actor, %{
               status: :AT_PICKUP,
               occurred_at: ~U[2026-10-21 10:00:00Z],
               device_id: mine.id,
               device_sequence: 1,
               signed: %{
                 fields: Map.delete(fields, "device_signature"),
                 signature: fields["device_signature"]
               }
             })
  end

  test "a registered device's declarations carry its signature, and are DEVICE_AUTHENTICATED",
       ctx do
    {_public_key, seed} = keys = Crypto.generate_keypair()
    registered = post("/v1/me/devices", registration(ctx, "install-1", keys), ctx.token)
    device_id = Jason.decode!(registered.resp_body)["device_id"]

    declaration =
      Fixtures.signed(
        %{
          "event_id" => Ash.UUID.generate(),
          "status" => "EN_ROUTE_PICKUP",
          "occurred_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
          "device_id" => device_id,
          "device_sequence" => 1
        },
        seed
      )

    conn = post("/v1/me/status-events", declaration, ctx.token)
    assert conn.status == 201
    assert Jason.decode!(conn.resp_body)["event"]["verification"] == "DEVICE_AUTHENTICATED"
  end
end
