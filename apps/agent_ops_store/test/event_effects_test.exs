defmodule AgentOpsStore.EventEffectsTest do
  use ExUnit.Case, async: true

  alias AgentOpsStore.EventEffects

  @accepted %{
    type: "TaskAgentRunRequestedV1",
    global_seq: 3,
    chapter_id: "chapter-one",
    event_id: "signed-event1"
  }

  test "accepted run intent derives only a non-executable operational candidate" do
    assert {:ok, [%{effect_id: "agent-run:signed-event1", kind: "agent-run-request"}]} =
             EventEffects.derive(@accepted, [])
  end

  test "current authority-changing events produce recheck intents, not permissions" do
    for {type, kind} <- [
          {"TaskAgentRunCancelledV1", "run-cancellation"},
          {"TaskAccessRevokedV1", "grant-revocation"},
          {"TaskPrincipalOffboardedV1", "principal-offboarding"}
        ] do
      assert {:ok, [%{effect_id: "agent-reconcile:signed-event1", kind: ^kind}]} =
               EventEffects.derive(%{@accepted | type: type}, [])
    end
  end

  test "unmapped events stop replay unless reviewed as explicit no-op" do
    event = %{@accepted | type: "UnknownNewDomainEventV2"}
    assert {:error, :event_type_not_reviewed} = EventEffects.derive(event, [])

    assert {:ok, []} =
             EventEffects.derive(event, ignored_types: ["UnknownNewDomainEventV2"])

    assert {:error, :invalid_ignored_event_types} =
             EventEffects.derive(event, ignored_types: ["TaskAgentRunRequestedV1"])
  end

  test "bad ledger locations cannot derive effect IDs" do
    assert {:error, :invalid_committed_event} =
             EventEffects.derive(%{@accepted | global_seq: 0}, [])

    assert {:error, :invalid_committed_event} =
             EventEffects.derive(%{@accepted | event_id: "../untrusted"}, [])

    assert {:error, :invalid_committed_event} =
             EventEffects.derive(%{@accepted | chapter_id: "bad/path"}, [])

    assert {:error, :invalid_committed_event} = EventEffects.derive(%{}, [])
  end
end
