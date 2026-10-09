defmodule Dispatch.Integrations.UnconfiguredAdaptersTest do
  @moduledoc """
  ADR-0004 makes these the development defaults. Section 8.6 requires a
  deterministic fallback rather than invented state, and Section 28.3 requires a
  routing failure to leave the previous route visibly stale rather than
  fabricate an ETA. A fake that quietly returned a plausible success would
  satisfy neither, so these assert that none of them can.
  """

  use ExUnit.Case, async: true

  alias Dispatch.Integrations.Comms.Unconfigured
  alias Dispatch.Integrations.Geo

  test "every unconfigured communications operation fails deterministically" do
    message = %Dispatch.Comms.OutboundMessage{
      message_id: "m",
      conversation_id: "c",
      to_e164: "+15005550001",
      from_e164: "+15005550002",
      body: "x",
      idempotency_key: "k"
    }

    call = %Dispatch.Comms.InboundCall{
      call_id: "c",
      provider: :NONE,
      provider_event_id: "e",
      from_e164: "+15005550001",
      to_e164: "+15005550002",
      occurred_at: DateTime.utc_now()
    }

    assert Unconfigured.Messaging.send_message(message) == Unconfigured.error()
    assert Unconfigured.Voice.answer(call) == Unconfigured.error()
    assert Unconfigured.VoiceMedia.accept_session(%{}) == Unconfigured.error()
  end

  test "an unconfigured router returns an error rather than a zero-distance route" do
    request = %Dispatch.Geo.RouteRequest{
      origin: %Dispatch.Geo.Coordinate{lat: 0.0, lng: 0.0},
      destination: %Dispatch.Geo.Coordinate{lat: 1.0, lng: 1.0}
    }

    assert {:error, :geo_adapter_not_configured} = Geo.Unconfigured.Router.route(request)
    assert {:error, :geo_adapter_not_configured} = Geo.Unconfigured.Geocoder.search("x", %{})
  end

  test "the contract agent adapter never emits a tool call" do
    request = %Dispatch.Agent.SessionRequest{
      agent_session_id: "s",
      channel: :VOICE,
      tool_allowlist: ["get_participant_context"]
    }

    {:ok, session} = Dispatch.Integrations.Agent.Fake.Runtime.open_session(request)

    {:ok, result} =
      Dispatch.Integrations.Agent.Fake.Runtime.run_turn(%Dispatch.Agent.TurnRequest{
        session: session,
        input: "anything",
        tool_allowlist: request.tool_allowlist
      })

    # Section 33.2: replaying an evaluation corpus against a second adapter must
    # never execute a tool or create a domain mutation.
    assert result.tool_calls == []
    assert result.finish_reason == :STOP
  end

  test "an AnswerPlan has no field that could carry a destination number" do
    # Section 8.2: no inbound call may ring, bridge, transfer, or conference the
    # driver. The absence of the field is the enforcement.
    fields =
      %Dispatch.Comms.AnswerPlan{
        call_id: "c",
        disclosure_text: "d",
        media_session_token: "t"
      }
      |> Map.keys()

    refute Enum.any?(fields, fn field ->
             Atom.to_string(field) =~ ~r/(dial|to_e164|destination|transfer|conference|driver)/
           end)
  end
end
