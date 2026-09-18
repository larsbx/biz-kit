defmodule DispatchWeb.StatusEventControllerTest do
  @moduledoc """
  The `/v1` status-ingestion surface of Section 24.1, end to end: bearer token,
  role-assignment selection, Ash policy, stored event.

  Section 33.2 requires specifically that "`/v1/driver` compatibility requests
  and `/v1/me` canonical requests create the same participant-scoped event" —
  the compatibility route is a projection, not a second implementation, and
  nothing but a test comparing the two keeps it that way.
  """

  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias Dispatch.Operations.ParticipantStatusEvent
  alias Dispatch.Support.Fixtures
  alias Dispatch.Support.Tokens.StaticVerifier

  require Ash.Query

  @moduletag :integration

  @opts DispatchWeb.Router.init([])

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Dispatch.Repo)

    org = Fixtures.carrier()
    tenant = org.id
    %{user: user, participant: driver} = Fixtures.person(tenant, org)
    assignment = Fixtures.assignment(tenant, org, driver, "DRIVER")

    %{
      org: org,
      tenant: tenant,
      user: user,
      driver: driver,
      assignment: assignment,
      token: StaticVerifier.token_for(user.oidc_subject)
    }
  end

  defp post(path, body, opts) do
    headers =
      [{"content-type", "application/json"}] ++
        Keyword.get(opts, :headers, []) ++
        case Keyword.get(opts, :token) do
          nil -> []
          token -> [{"authorization", "Bearer " <> token}]
        end

    :post
    |> conn(path, Jason.encode!(body))
    |> Plug.RequestId.call(Plug.RequestId.init(assign_as: :correlation_id))
    |> then(fn conn ->
      Enum.reduce(headers, conn, fn {k, v}, c -> put_req_header(c, k, v) end)
    end)
    |> Plug.Parsers.call(Plug.Parsers.init(parsers: [:json], pass: ["*/*"], json_decoder: Jason))
    |> DispatchWeb.Router.call(@opts)
  end

  defp declaration(overrides \\ %{}) do
    Map.merge(
      %{
        "status" => "EN_ROUTE_PICKUP",
        "occurred_at" => DateTime.utc_now() |> DateTime.to_iso8601()
      },
      overrides
    )
  end

  describe "authentication (Section 23.1)" do
    test "an unauthenticated request is refused as an RFC 9457 problem", ctx do
      conn = post("/v1/me/status-events", declaration(), token: nil)

      assert conn.status == 401
      assert get_resp_header(conn, "content-type") == ["application/problem+json; charset=utf-8"]

      problem = Jason.decode!(conn.resp_body)
      assert problem["code"] == "UNAUTHENTICATED"
      assert problem["status"] == 401
      assert problem["instance"] == "/v1/me/status-events"
      # Section 19.2 requires a correlation ID on every error response.
      assert is_binary(problem["correlation_id"])
      refute problem["correlation_id"] == "unassigned"

      assert [] = read_events(ctx)
    end

    test "an expired token is refused", ctx do
      expired =
        StaticVerifier.token_for(ctx.user.oidc_subject,
          expires_at: DateTime.add(DateTime.utc_now(), -1, :second)
        )

      conn = post("/v1/me/status-events", declaration(), token: expired)

      assert conn.status == 401
      assert Jason.decode!(conn.resp_body)["code"] == "UNAUTHENTICATED"
    end

    test "a token for a principal with no active assignment is refused", ctx do
      %{user: stranger} = Fixtures.person(ctx.tenant, ctx.org)

      conn =
        post("/v1/me/status-events", declaration(),
          token: StaticVerifier.token_for(stranger.oidc_subject)
        )

      assert conn.status == 403
      assert Jason.decode!(conn.resp_body)["code"] == "NO_ACTIVE_ROLE_ASSIGNMENT"
    end
  end

  describe "role-assignment selection (Section 24.6)" do
    test "the header selects among assignments the principal holds", ctx do
      dispatcher = Fixtures.assignment(ctx.tenant, ctx.org, ctx.driver, "DISPATCHER")

      # Two active assignments and no header: Section 23.3 forbids unioning
      # their capabilities, so the request must say which one it acts under.
      conn = post("/v1/me/status-events", declaration(), token: ctx.token)
      assert conn.status == 403
      assert Jason.decode!(conn.resp_body)["code"] == "ROLE_ASSIGNMENT_REQUIRED"

      # Naming the DRIVER assignment succeeds: it carries status.declare.self.
      conn =
        post("/v1/me/status-events", declaration(),
          token: ctx.token,
          headers: [{"x-role-assignment-id", ctx.assignment.id}]
        )

      assert conn.status == 201

      # Naming the DISPATCHER assignment does not. The same person, the same
      # token — the selected authority is what differs, which is the whole
      # point of Section 23.3's refusal to union.
      conn =
        post("/v1/me/status-events", declaration(),
          token: ctx.token,
          headers: [{"x-role-assignment-id", dispatcher.id}]
        )

      assert conn.status == 403
      assert Jason.decode!(conn.resp_body)["code"] == "FORBIDDEN"
    end

    test "a header naming an assignment held by someone else selects nothing", ctx do
      %{participant: other} = Fixtures.person(ctx.tenant, ctx.org)
      theirs = Fixtures.assignment(ctx.tenant, ctx.org, other, "DISPATCHER")

      conn =
        post("/v1/me/status-events", declaration(),
          token: ctx.token,
          headers: [{"x-role-assignment-id", theirs.id}]
        )

      assert conn.status == 403
      assert Jason.decode!(conn.resp_body)["code"] == "ROLE_ASSIGNMENT_INVALID"
      assert [] = read_events(ctx)
    end

    test "a revoked assignment stops working immediately", ctx do
      ctx.assignment
      |> Ash.Changeset.for_update(:revoke, %{})
      |> Ash.update!(authorize?: false, tenant: ctx.tenant)

      conn = post("/v1/me/status-events", declaration(), token: ctx.token)

      assert conn.status == 403
      assert Jason.decode!(conn.resp_body)["code"] == "NO_ACTIVE_ROLE_ASSIGNMENT"
    end
  end

  describe "declaring a status (Section 24.1)" do
    test "stores the event and returns it with the current status", ctx do
      conn = post("/v1/me/status-events", declaration(), token: ctx.token)

      assert conn.status == 201
      body = Jason.decode!(conn.resp_body)

      assert body["event"]["status"] == "EN_ROUTE_PICKUP"
      # Section 5.2: a status is a declaration, so the source is the participant.
      assert body["event"]["source"] == "PARTICIPANT"
      # Section 24.1 derives the participant from the token, never the body.
      assert body["event"]["participant_id"] == ctx.driver.id
      assert body["event"]["role_assignment_id"] == ctx.assignment.id

      assert body["current_status"]["value"] == "EN_ROUTE_PICKUP"
      assert body["current_status"]["source"] == "PARTICIPANT"
      assert body["current_status"]["role_key"] == "DRIVER"
    end

    test "a participant identifier in the body is ignored, not honoured", ctx do
      %{participant: victim} = Fixtures.person(ctx.tenant, ctx.org)

      conn =
        post("/v1/me/status-events", declaration(%{"participant_id" => victim.id}),
          token: ctx.token
        )

      assert conn.status == 201
      assert Jason.decode!(conn.resp_body)["event"]["participant_id"] == ctx.driver.id
    end

    test "DELAYED without a note is rejected", ctx do
      conn = post("/v1/me/status-events", declaration(%{"status" => "DELAYED"}), token: ctx.token)

      assert conn.status == 422
      assert Jason.decode!(conn.resp_body)["code"] == "VALIDATION_FAILED"
    end

    test "an occurred_at more than five minutes ahead is rejected", ctx do
      ahead = DateTime.utc_now() |> DateTime.add(301, :second) |> DateTime.to_iso8601()

      conn =
        post("/v1/me/status-events", declaration(%{"occurred_at" => ahead}), token: ctx.token)

      assert conn.status == 422
    end

    test "an unparseable occurred_at is a malformed request", ctx do
      conn =
        post("/v1/me/status-events", declaration(%{"occurred_at" => "yesterday"}),
          token: ctx.token
        )

      assert conn.status == 400
      assert Jason.decode!(conn.resp_body)["code"] == "MALFORMED_REQUEST"
    end
  end

  describe "Section 33.2: the /v1/driver projection and /v1/me create the same event" do
    test "both routes produce a participant-scoped event of the same shape", ctx do
      canonical = post("/v1/me/status-events", declaration(), token: ctx.token)

      compatibility =
        post("/v1/driver/status-events", declaration(%{"status" => "AT_PICKUP"}),
          token: ctx.token
        )

      assert canonical.status == 201
      assert compatibility.status == 201

      one = Jason.decode!(canonical.resp_body)["event"]
      two = Jason.decode!(compatibility.resp_body)["event"]

      # Different declarations, but the same participant, the same authority,
      # and the same set of fields — one projection of one resource.
      assert Map.keys(one) == Map.keys(two)
      assert one["participant_id"] == two["participant_id"]
      assert one["role_assignment_id"] == two["role_assignment_id"]
      assert one["source"] == two["source"]

      assert length(read_events(ctx)) == 2
    end
  end

  describe "Section 24.1: an assignment must belong to the caller" do
    test "a declaration naming another participant's assignment is refused", ctx do
      %{participant: other} = Fixtures.person(ctx.tenant, ctx.org)
      theirs = Fixtures.assignment_record(ctx.tenant, ctx.org, other)

      conn =
        post("/v1/me/status-events", declaration(%{"assignment_id" => theirs.id}),
          token: ctx.token
        )

      assert conn.status == 422
      assert [] = read_events(ctx)
    end

    test "a declaration naming an assignment in another tenant is refused", ctx do
      elsewhere = Fixtures.carrier()
      %{participant: stranger} = Fixtures.person(elsewhere.id, elsewhere)
      theirs = Fixtures.assignment_record(elsewhere.id, elsewhere, stranger)

      # The sharper case: a tenant-A event linked to a tenant-B assignment would
      # corrupt assignment-scoped history across the tenant boundary.
      conn =
        post("/v1/me/status-events", declaration(%{"assignment_id" => theirs.id}),
          token: ctx.token
        )

      assert conn.status == 422
      assert [] = read_events(ctx)
    end

    test "a declaration naming the caller's own assignment is accepted", ctx do
      mine = Fixtures.assignment_record(ctx.tenant, ctx.org, ctx.driver)

      conn =
        post("/v1/me/status-events", declaration(%{"assignment_id" => mine.id}), token: ctx.token)

      assert conn.status == 201
      assert Jason.decode!(conn.resp_body)["event"]["assignment_id"] == mine.id
    end
  end

  describe "Section 22.3: a device sequence belongs to a device the caller owns" do
    test "a declaration naming another participant's device is refused", ctx do
      %{participant: other} = Fixtures.person(ctx.tenant, ctx.org)
      theirs = Fixtures.device(ctx.tenant, other)

      conn =
        post(
          "/v1/me/status-events",
          declaration(%{"device_id" => theirs.id, "device_sequence" => 1}),
          token: ctx.token
        )

      assert conn.status == 422
      assert [] = read_events(ctx)
    end

    test "a declaration naming a revoked device is refused", ctx do
      device = Fixtures.device(ctx.tenant, ctx.driver)

      device
      |> Ash.Changeset.for_update(:revoke, %{})
      |> Ash.update!(authorize?: false, tenant: ctx.tenant)

      conn =
        post(
          "/v1/me/status-events",
          declaration(%{"device_id" => device.id, "device_sequence" => 1}),
          token: ctx.token
        )

      # Section 13 makes revocation lost-device handling. A revoked handset
      # must not keep consuming sequence numbers.
      assert conn.status == 422
      assert [] = read_events(ctx)
    end

    test "a declaration naming a device in another tenant is refused", ctx do
      elsewhere = Fixtures.carrier()
      %{participant: stranger} = Fixtures.person(elsewhere.id, elsewhere)
      theirs = Fixtures.device(elsewhere.id, stranger)

      # `devices.installation_id` and the status-event sequence index are both
      # global (Section 22.3), so an unchecked device ID lets one tenant consume
      # another tenant's sequence numbers.
      conn =
        post(
          "/v1/me/status-events",
          declaration(%{"device_id" => theirs.id, "device_sequence" => 1}),
          token: ctx.token
        )

      assert conn.status == 422
      assert [] = read_events(ctx)
    end

    test "a declaration naming the caller's own active device is accepted", ctx do
      device = Fixtures.device(ctx.tenant, ctx.driver)

      conn =
        post(
          "/v1/me/status-events",
          declaration(%{"device_id" => device.id, "device_sequence" => 1}),
          token: ctx.token
        )

      assert conn.status == 201
      assert Jason.decode!(conn.resp_body)["event"]["device_id"] == device.id
    end
  end

  describe "Section 24.1: the client-assigned event_id" do
    test "is persisted as the event's identity", ctx do
      id = Ash.UUID.generate()

      conn = post("/v1/me/status-events", declaration(%{"event_id" => id}), token: ctx.token)

      assert conn.status == 201
      # The contract calls it client-assigned. A field the server accepts and
      # discards is worse than one it never advertised: an offline client
      # reconciling by ID would never find its own event.
      assert Jason.decode!(conn.resp_body)["event"]["id"] == id
    end

    test "replaying the same event_id returns the original event, not a second one", ctx do
      id = Ash.UUID.generate()
      body = declaration(%{"event_id" => id})

      first = post("/v1/me/status-events", body, token: ctx.token)
      second = post("/v1/me/status-events", body, token: ctx.token)

      assert first.status == 201
      assert second.status == 201
      assert Jason.decode!(second.resp_body)["event"]["id"] == id
      assert length(read_events(ctx)) == 1
    end
  end

  describe "Section 24.1: a client-assigned event_id claimed by someone else" do
    test "is refused as a conflict, not a server error, and discloses nothing", ctx do
      %{user: other_user, participant: other} = Fixtures.person(ctx.tenant, ctx.org)

      Fixtures.assignment(ctx.tenant, ctx.org, other, "DRIVER",
        definition: Fixtures.role_definition_for(ctx.tenant, ctx.assignment)
      )

      id = Ash.UUID.generate()

      mine = post("/v1/me/status-events", declaration(%{"event_id" => id}), token: ctx.token)
      assert mine.status == 201

      # A UUIDv7 collision is not reachable by accident, but a deliberate one
      # must not surface as a 500 — nor tell the caller whose event it is.
      theirs =
        post("/v1/me/status-events", declaration(%{"event_id" => id}),
          token: StaticVerifier.token_for(other_user.oidc_subject)
        )

      assert theirs.status == 409
      problem = Jason.decode!(theirs.resp_body)
      assert problem["code"] == "EVENT_ID_CONFLICT"
      refute problem["detail"] =~ ctx.driver.id
    end
  end

  describe "device sequences (Sections 22.3, 24.1)" do
    test "a retry with the same content returns the original event", ctx do
      device = Fixtures.device(ctx.tenant, ctx.driver).id
      body = declaration(%{"device_id" => device, "device_sequence" => 412})

      first = post("/v1/me/status-events", body, token: ctx.token)
      second = post("/v1/me/status-events", body, token: ctx.token)

      assert first.status == 201
      assert second.status == 201

      # The *original* 201 body, not a second event that looks like it.
      assert Jason.decode!(first.resp_body)["event"]["id"] ==
               Jason.decode!(second.resp_body)["event"]["id"]

      assert length(read_events(ctx)) == 1
    end

    test "the same sequence with different content is a conflict", ctx do
      device = Fixtures.device(ctx.tenant, ctx.driver).id
      at = DateTime.utc_now() |> DateTime.to_iso8601()

      first =
        post(
          "/v1/me/status-events",
          declaration(%{"device_id" => device, "device_sequence" => 7, "occurred_at" => at}),
          token: ctx.token
        )

      second =
        post(
          "/v1/me/status-events",
          declaration(%{
            "device_id" => device,
            "device_sequence" => 7,
            "occurred_at" => at,
            "status" => "AT_PICKUP"
          }),
          token: ctx.token
        )

      assert first.status == 201
      assert second.status == 409
      assert Jason.decode!(second.resp_body)["code"] == "DEVICE_SEQUENCE_CONFLICT"
      assert length(read_events(ctx)) == 1
    end
  end

  describe "idempotency keys (Section 24)" do
    test "a replayed key returns the stored response without a second event", ctx do
      body = declaration()
      headers = [{"idempotency-key", "key-" <> Ash.UUID.generate()}]

      first = post("/v1/me/status-events", body, token: ctx.token, headers: headers)
      second = post("/v1/me/status-events", body, token: ctx.token, headers: headers)

      assert first.status == 201
      assert second.status == 201
      assert Jason.decode!(first.resp_body) == Jason.decode!(second.resp_body)
      assert length(read_events(ctx)) == 1
    end

    test "reusing a key for a different request is refused", ctx do
      headers = [{"idempotency-key", "key-" <> Ash.UUID.generate()}]

      first = post("/v1/me/status-events", declaration(), token: ctx.token, headers: headers)

      second =
        post("/v1/me/status-events", declaration(%{"status" => "AT_PICKUP"}),
          token: ctx.token,
          headers: headers
        )

      assert first.status == 201
      assert second.status == 409
      assert Jason.decode!(second.resp_body)["code"] == "IDEMPOTENCY_KEY_REUSED"
      assert length(read_events(ctx)) == 1
    end

    test "a rejected request releases its key for a corrected retry", ctx do
      headers = [{"idempotency-key", "key-" <> Ash.UUID.generate()}]

      rejected =
        post("/v1/me/status-events", declaration(%{"status" => "DELAYED"}),
          token: ctx.token,
          headers: headers
        )

      assert rejected.status == 422

      # The same key, now carrying a valid declaration. Storing the failure
      # would have made a transient client error permanent for 24 hours.
      corrected =
        post("/v1/me/status-events", declaration(%{"status" => "DELAYED", "note" => "Traffic"}),
          token: ctx.token,
          headers: headers
        )

      assert corrected.status == 201
    end

    test "two actors may use the same key string independently", ctx do
      %{user: other_user, participant: other} = Fixtures.person(ctx.tenant, ctx.org)

      Fixtures.assignment(ctx.tenant, ctx.org, other, "DRIVER",
        definition:
          Ash.get!(Dispatch.Accounts.RoleDefinition, ctx.assignment.role_definition_id,
            authorize?: false,
            tenant: ctx.tenant
          )
      )

      headers = [{"idempotency-key", "shared-key"}]

      mine = post("/v1/me/status-events", declaration(), token: ctx.token, headers: headers)

      theirs =
        post("/v1/me/status-events", declaration(),
          token: StaticVerifier.token_for(other_user.oidc_subject),
          headers: headers
        )

      assert mine.status == 201
      assert theirs.status == 201

      refute Jason.decode!(mine.resp_body)["event"]["id"] ==
               Jason.decode!(theirs.resp_body)["event"]["id"]
    end
  end

  defp read_events(ctx) do
    ParticipantStatusEvent
    |> Ash.Query.filter(participant_id == ^ctx.driver.id)
    |> Ash.read!(authorize?: false, tenant: ctx.tenant)
  end
end
