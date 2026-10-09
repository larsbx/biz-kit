defmodule DispatchWeb.Schemas.StatusEventRequest do
  @moduledoc """
  The body of `POST /v1/me/status-events` (Section 24.1).

  No participant identifier appears here. Section 24.1 derives it from the
  authenticated actor, and a field a client cannot send is a stronger guarantee
  than one the server ignores.
  """

  alias Dispatch.Operations.Status
  alias OpenApiSpex.Schema

  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "StatusEventRequest",
    type: :object,
    properties: %{
      event_id: %Schema{
        type: :string,
        format: :uuid,
        description:
          "Client-assigned UUIDv7. Becomes the stored event's ID, so an offline " <>
            "client can reconcile by the identifier it recorded before uploading. " <>
            "Omitted, the server assigns one. Already in use: 409 EVENT_ID_CONFLICT."
      },
      assignment_id: %Schema{type: :string, format: :uuid},
      status: %Schema{type: :string, enum: Enum.map(Status.all(), &Atom.to_string/1)},
      occurred_at: %Schema{
        type: :string,
        format: :"date-time",
        description: "RFC 3339 UTC. May not exceed server time by more than five minutes."
      },
      note: %Schema{
        type: :string,
        maxLength: 1_000,
        description: "Required and nonblank for DELAYED and BREAKDOWN."
      },
      location_sample_id: %Schema{type: :string, format: :uuid},
      device_id: %Schema{type: :string, format: :uuid},
      device_sequence: %Schema{type: :integer, minimum: 0},
      device_signature: %Schema{type: :string},
      supersedes_event_id: %Schema{
        type: :string,
        format: :uuid,
        description: "The event this corrects. History is appended, never rewritten."
      }
    },
    required: [:status, :occurred_at],
    additionalProperties: false
  })
end

defmodule DispatchWeb.Schemas.StatusEvent do
  @moduledoc "A stored participant status declaration (Section 22.3)."

  alias Dispatch.Operations.Status
  alias OpenApiSpex.Schema

  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "StatusEvent",
    type: :object,
    properties: %{
      id: %Schema{type: :string, format: :uuid},
      participant_id: %Schema{type: :string, format: :uuid},
      role_assignment_id: %Schema{type: :string, format: :uuid},
      assignment_id: %Schema{type: :string, format: :uuid, nullable: true},
      status: %Schema{type: :string, enum: Enum.map(Status.all(), &Atom.to_string/1)},
      source: %Schema{
        type: :string,
        enum: ["PARTICIPANT"],
        description: "Section 5.2: a status is a declaration, so this is always PARTICIPANT."
      },
      occurred_at: %Schema{type: :string, format: :"date-time"},
      recorded_at: %Schema{
        type: :string,
        format: :"date-time",
        description: "When the server stored it; distinct from occurred_at for offline events."
      },
      note: %Schema{type: :string, nullable: true},
      location_sample_id: %Schema{type: :string, format: :uuid, nullable: true},
      verification: %Schema{
        type: :string,
        enum: ["NONE", "DEVICE_AUTHENTICATED", "SYSTEM_BIOMETRIC", "FACE_1_TO_1"]
      },
      supersedes_event_id: %Schema{type: :string, format: :uuid, nullable: true},
      device_id: %Schema{type: :string, format: :uuid, nullable: true},
      device_sequence: %Schema{type: :integer, nullable: true}
    },
    required: [
      :id,
      :participant_id,
      :role_assignment_id,
      :status,
      :source,
      :occurred_at,
      :recorded_at,
      :verification
    ],
    additionalProperties: false
  })
end

defmodule DispatchWeb.Schemas.CurrentStatus do
  @moduledoc """
  The participant's current status after the declaration (Section 24.1).

  Carries `source` and `role_key` because Section 1 keeps a declaration distinct
  from an observation or an inference, and a consumer that cannot see which it
  is has lost the distinction.
  """

  alias Dispatch.Operations.Status
  alias OpenApiSpex.Schema

  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "CurrentStatus",
    type: :object,
    properties: %{
      value: %Schema{type: :string, enum: Enum.map(Status.all(), &Atom.to_string/1)},
      source: %Schema{type: :string, enum: ["PARTICIPANT"]},
      role_key: %Schema{type: :string},
      occurred_at: %Schema{type: :string, format: :"date-time"}
    },
    required: [:value, :source, :role_key, :occurred_at],
    additionalProperties: false
  })
end

defmodule DispatchWeb.Schemas.StatusEventResponse do
  @moduledoc "The `201` body of Section 24.1: the stored event and the resulting status."

  alias DispatchWeb.Schemas.{CurrentStatus, StatusEvent}

  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "StatusEventResponse",
    type: :object,
    properties: %{
      event: StatusEvent,
      current_status: CurrentStatus
    },
    required: [:event, :current_status],
    additionalProperties: false
  })
end
