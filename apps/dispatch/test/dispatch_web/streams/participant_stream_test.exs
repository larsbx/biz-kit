defmodule DispatchWeb.Streams.ParticipantTest do
  @moduledoc """
  A live stream's authorization over time (Sections 24.5, 33.2).

  A page authorizes once, answers, and is gone. A stream authorizes once and
  then keeps answering for as long as it is open — which makes "authorized" a
  claim about every tick, not about the request that started it.

  Section 33.2 is explicit that this is where the difference bites: "Expired,
  revoked, wrong-tenant, and wrong-scope role assignments fail closed across
  REST, Datastar, agent tools, jobs, and SSE reconnects", and acceptance
  criterion 16 says a dispatcher "loses an operations stream *immediately* when
  its carrier/load relationship ends".

  These tests drive the stream a tick at a time rather than sleeping and hoping.
  A test that revoked a grant, waited, and checked the socket would pass whether
  the stream noticed or merely timed out; driving it means the assertion is that
  the *next* tick closes, which is what "immediately" has to mean for something
  that only acts when it ticks.
  """

  use ExUnit.Case, async: false

  alias Dispatch.Support.Fixtures
  alias DispatchWeb.Streams.Participant

  @moduletag :integration

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Dispatch.Repo)

    carrier = Fixtures.carrier()
    tenant = carrier.id

    %{participant: driver} = Fixtures.person(tenant, carrier)
    %{participant: dispatcher} = Fixtures.person(tenant, carrier)
    %{participant: admin} = Fixtures.person(tenant, carrier)

    %{
      tenant: tenant,
      carrier: carrier,
      driver: driver,
      actor: Fixtures.actor(tenant, carrier, dispatcher, "DISPATCHER"),
      admin_actor: Fixtures.actor(tenant, carrier, admin, "ADMIN")
    }
  end

  describe "opening a stream" do
    test "sends a retry hint and an authorized initial snapshot", ctx do
      assert {:ok, _session, chunk} = Participant.open(ctx.actor, ctx.driver.id)

      body = IO.iodata_to_binary(chunk)

      # Section 24.5: a stream sends an initial snapshot, so a client that
      # connects to a quiet stream is not staring at an empty page.
      assert body =~ "retry: "
      assert body =~ "event: datastar-patch-elements"
      assert body =~ "participant-status-card"
    end

    test "an unauthorized viewer gets no stream and no fragment", ctx do
      # Section 33.2: "An unauthorized stream and map-data request returns no
      # protected fragment or coordinates." The refusal must not leak the
      # snapshot it declined to stream.
      assert Participant.open(ctx.admin_actor, ctx.driver.id) == {:error, :not_found}
    end

    test "a participant in another tenant bears no existence", ctx do
      elsewhere = Fixtures.carrier()
      %{participant: stranger} = Fixtures.person(elsewhere.id, elsewhere)

      assert Participant.open(ctx.actor, stranger.id) == {:error, :not_found}
      assert Participant.open(ctx.actor, Ash.UUID.generate()) == {:error, :not_found}
    end
  end

  describe "acceptance criterion 16: the stream closes when the grant ends" do
    test "the next tick after revocation closes it", ctx do
      {:ok, session, _snapshot} = Participant.open(ctx.actor, ctx.driver.id)

      # Still live before anything changes.
      assert {:emit, _heartbeat, session} = Participant.tick(session, :heartbeat)

      Fixtures.revoke(ctx.tenant, ctx.actor.role_assignment)

      # No new domain event, no reconnect — just the next beat of a stream that
      # was already open. That is the only tick "immediately" can mean here, and
      # it is the one an open socket actually experiences.
      assert {:close, :unauthorized} = Participant.tick(session, :heartbeat)
    end

    test "a refresh tick after revocation closes rather than emitting", ctx do
      {:ok, session, _snapshot} = Participant.open(ctx.actor, ctx.driver.id)

      Fixtures.revoke(ctx.tenant, ctx.actor.role_assignment)

      # The dangerous ordering: a domain event arrives at the same moment the
      # grant ends. Rendering first and checking later would emit one last
      # authorized-looking fragment to someone who is no longer authorized.
      assert {:close, :unauthorized} = Participant.tick(session, :refresh)
    end

    test "an unrevoked stream keeps emitting", ctx do
      {:ok, session, _snapshot} = Participant.open(ctx.actor, ctx.driver.id)

      assert {:emit, _one, session} = Participant.tick(session, :heartbeat)
      assert {:emit, chunk, _session} = Participant.tick(session, :refresh)

      # Guards against a fix that closes everything: fail-closed is only useful
      # if the open case still works.
      assert IO.iodata_to_binary(chunk) =~ "participant-status-card"
    end
  end

  describe "Section 24.5: the wire format" do
    test "a heartbeat is a comment frame terminated by a blank line", ctx do
      {:ok, session, _snapshot} = Participant.open(ctx.actor, ctx.driver.id)

      assert {:emit, chunk, _session} = Participant.tick(session, :heartbeat)
      assert IO.iodata_to_binary(chunk) == ": heartbeat\n\n"
    end

    test "a patch uses repeated data: elements lines and ends with a blank line", ctx do
      {:ok, session, _snapshot} = Participant.open(ctx.actor, ctx.driver.id)
      {:emit, chunk, _session} = Participant.tick(session, :refresh)

      body = IO.iodata_to_binary(chunk)

      assert body =~ "event: datastar-patch-elements\n"
      assert String.ends_with?(body, "\n\n")

      # Every line of the fragment carries its own prefix. A multi-line fragment
      # sent as one `data:` line is not the same event to a client.
      data_lines = body |> String.split("\n") |> Enum.filter(&String.starts_with?(&1, "data: "))
      assert length(data_lines) > 1
      assert Enum.all?(data_lines, &String.starts_with?(&1, "data: elements "))
    end

    test "every event carries an id a client can present on reconnect", ctx do
      {:ok, session, _snapshot} = Participant.open(ctx.actor, ctx.driver.id)
      {:emit, chunk, _session} = Participant.tick(session, :refresh)

      assert IO.iodata_to_binary(chunk) =~ ~r/^id: .+$/m
    end
  end

  describe "Section 24.5: reconnecting" do
    test "an unknown Last-Event-ID produces a fresh snapshot, not a replay", ctx do
      {:ok, _session, chunk} =
        Participant.open(ctx.actor, ctx.driver.id, last_event_id: "not-an-id-we-issued")

      body = IO.iodata_to_binary(chunk)

      # Section 24.5: "If replay is unavailable, the server sends fresh
      # snapshots for every subscribed region rather than attempting
      # client-side reconciliation."
      assert body =~ "participant-status-card"
      assert body =~ "event: datastar-patch-elements"
    end

    test "a reconnect is authorized afresh, not trusted from the previous stream", ctx do
      Fixtures.revoke(ctx.tenant, ctx.actor.role_assignment)

      # Section 33.2 names SSE reconnects specifically. A client holding a
      # Last-Event-ID from an authorized stream must not use it to resume one.
      assert Participant.open(ctx.actor, ctx.driver.id, last_event_id: "anything") ==
               {:error, :not_found}
    end
  end
end
