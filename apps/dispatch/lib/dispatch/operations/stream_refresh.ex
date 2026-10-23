defmodule Dispatch.Operations.StreamRefresh do
  @moduledoc """
  Tells the portal's open streams (Section 24.5) that a participant's facts
  changed: the participant's own page and their organization's roster. Written
  to the outbox inside the change's transaction, so a stream learns of exactly
  what committed.
  """

  alias Dispatch.Access.Actor

  @doc "Queues a refresh of `participant_id`'s page and of the actor's roster."
  @spec enqueue!(Actor.t(), Ash.UUID.t(), String.t(), map()) :: :ok
  def enqueue!(%Actor{} = actor, participant_id, event_type, payload) do
    now = DateTime.utc_now()

    for topic <- [
          "participant:#{participant_id}",
          "operations:#{actor.role_assignment.organization_id}"
        ] do
      Dispatch.Repo.insert!(%Dispatch.Outbox.Event{
        id: Ash.UUID.generate(),
        tenant_id: actor.tenant_id,
        topic: topic,
        event_type: event_type,
        payload: payload,
        occurred_at: now
      })
    end

    :ok
  end
end
