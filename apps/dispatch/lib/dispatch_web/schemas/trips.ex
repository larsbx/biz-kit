defmodule DispatchWeb.Schemas.Trip do
  @moduledoc "One of the caller's own trips not yet over, with the location consent covering it now."

  alias OpenApiSpex.Schema

  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "Trip",
    type: :object,
    properties: %{
      assignment_id: %Schema{type: :string, format: :uuid},
      load_id: %Schema{type: :string, format: :uuid},
      status: %Schema{type: :string, enum: ["PLANNED", "ACTIVE"]},
      starts_at: %Schema{type: :string, format: :"date-time"},
      ends_at: %Schema{type: :string, format: :"date-time", nullable: true},
      location_consent: %Schema{
        allOf: [DispatchWeb.Schemas.LocationConsent],
        nullable: true,
        description: "The consent covering this trip now, or null: none, revoked or expired."
      }
    },
    required: [:assignment_id, :load_id, :status, :starts_at, :ends_at, :location_consent],
    additionalProperties: false
  })
end

defmodule DispatchWeb.Schemas.TripList do
  @moduledoc "The body of `GET /v1/me/assignments`: soonest first."

  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "TripList",
    type: :object,
    properties: %{assignments: %OpenApiSpex.Schema{type: :array, items: DispatchWeb.Schemas.Trip}},
    required: [:assignments],
    additionalProperties: false
  })
end
