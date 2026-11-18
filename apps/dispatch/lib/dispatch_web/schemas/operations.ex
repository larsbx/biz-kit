defmodule DispatchWeb.Schemas.BoardStop do
  @moduledoc "One stop of a load on the dispatch board, in sequence order."

  alias OpenApiSpex.Schema

  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "BoardStop",
    type: :object,
    properties: %{
      stop_id: %Schema{type: :string, format: :uuid},
      sequence: %Schema{type: :integer, minimum: 1},
      kind: %Schema{type: :string, enum: ["PICKUP", "DELIVERY", "OTHER"]},
      address_text: %Schema{type: :string},
      window_start: %Schema{type: :string, format: :"date-time", nullable: true},
      window_end: %Schema{type: :string, format: :"date-time", nullable: true},
      contact_name: %Schema{type: :string, nullable: true},
      contact_phone_e164: %Schema{type: :string, nullable: true}
    },
    required: [:stop_id, :sequence, :kind, :address_text],
    additionalProperties: false
  })
end

defmodule DispatchWeb.Schemas.BoardTrip do
  @moduledoc "One trip (assignment) of a load on the dispatch board."

  alias OpenApiSpex.Schema

  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "BoardTrip",
    type: :object,
    properties: %{
      assignment_id: %Schema{type: :string, format: :uuid},
      operator_participant_id: %Schema{type: :string, format: :uuid},
      vehicle_id: %Schema{type: :string, format: :uuid, nullable: true},
      trailer_id: %Schema{type: :string, format: :uuid, nullable: true},
      status: %Schema{type: :string, enum: ["PLANNED", "ACTIVE", "COMPLETED", "CANCELLED"]},
      starts_at: %Schema{type: :string, format: :"date-time"},
      ends_at: %Schema{type: :string, format: :"date-time", nullable: true},
      version: %Schema{type: :integer, description: "Send back as expected_version."}
    },
    required: [:assignment_id, :operator_participant_id, :status, :starts_at, :version],
    additionalProperties: false
  })
end

defmodule DispatchWeb.Schemas.BoardLoad do
  @moduledoc """
  One of the organization's loads with its stops and trips. The negotiated
  rate is never included (Section 4.2).
  """

  alias OpenApiSpex.Schema

  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "BoardLoad",
    type: :object,
    properties: %{
      load_id: %Schema{type: :string, format: :uuid},
      external_reference: %Schema{type: :string, nullable: true},
      commodity_text: %Schema{type: :string, nullable: true},
      status: %Schema{
        type: :string,
        enum: ["DRAFT", "TENDERED", "BOOKED", "IN_TRANSIT", "DELIVERED", "CANCELLED"]
      },
      created_at: %Schema{type: :string, format: :"date-time"},
      version: %Schema{type: :integer, description: "Send back as expected_version."},
      stops: %Schema{type: :array, items: DispatchWeb.Schemas.BoardStop},
      trips: %Schema{type: :array, items: DispatchWeb.Schemas.BoardTrip}
    },
    required: [:load_id, :status, :created_at, :version, :stops, :trips],
    additionalProperties: false
  })
end

defmodule DispatchWeb.Schemas.BoardLoadList do
  @moduledoc "The body of `GET /v1/operations/loads`: newest first."

  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "BoardLoadList",
    type: :object,
    properties: %{loads: %OpenApiSpex.Schema{type: :array, items: DispatchWeb.Schemas.BoardLoad}},
    required: [:loads],
    additionalProperties: false
  })
end

defmodule DispatchWeb.Schemas.Fleet do
  @moduledoc "The body of `GET /v1/operations/fleet`: what a trip can be planned with."

  alias OpenApiSpex.Schema

  require OpenApiSpex

  @unit %Schema{
    type: :object,
    properties: %{
      id: %Schema{type: :string, format: :uuid},
      unit_number: %Schema{type: :string},
      plate: %Schema{type: :string, nullable: true}
    },
    required: [:id, :unit_number],
    additionalProperties: false
  }

  OpenApiSpex.schema(%{
    title: "Fleet",
    type: :object,
    properties: %{
      drivers: %Schema{
        type: :array,
        items: %Schema{
          type: :object,
          properties: %{
            participant_id: %Schema{type: :string, format: :uuid},
            public_name: %Schema{type: :string}
          },
          required: [:participant_id, :public_name],
          additionalProperties: false
        }
      },
      vehicles: %Schema{type: :array, items: @unit},
      trailers: %Schema{type: :array, items: @unit}
    },
    required: [:drivers, :vehicles, :trailers],
    additionalProperties: false
  })
end

defmodule DispatchWeb.Schemas.LoadInput do
  @moduledoc "Creates a load, or changes its non-binding fields."

  alias OpenApiSpex.Schema

  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "LoadInput",
    type: :object,
    properties: %{
      external_reference: %Schema{type: :string, nullable: true},
      commodity_text: %Schema{type: :string, nullable: true},
      expected_version: %Schema{type: :integer, description: "Required when changing a load."}
    },
    additionalProperties: false
  })
end

defmodule DispatchWeb.Schemas.StopInput do
  @moduledoc "Appends a stop to a load."

  alias OpenApiSpex.Schema

  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "StopInput",
    type: :object,
    properties: %{
      kind: %Schema{type: :string, enum: ["PICKUP", "DELIVERY", "OTHER"]},
      address_text: %Schema{type: :string},
      window_start: %Schema{type: :string, format: :"date-time", nullable: true},
      window_end: %Schema{type: :string, format: :"date-time", nullable: true},
      contact_name: %Schema{type: :string, nullable: true},
      contact_phone_e164: %Schema{type: :string, nullable: true}
    },
    required: [:kind, :address_text],
    additionalProperties: false
  })
end

defmodule DispatchWeb.Schemas.TripInput do
  @moduledoc "Plans a trip for a load."

  alias OpenApiSpex.Schema

  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "TripInput",
    type: :object,
    properties: %{
      operator_participant_id: %Schema{type: :string, format: :uuid},
      vehicle_id: %Schema{type: :string, format: :uuid, nullable: true},
      trailer_id: %Schema{type: :string, format: :uuid, nullable: true},
      starts_at: %Schema{type: :string, format: :"date-time", nullable: true},
      ends_at: %Schema{type: :string, format: :"date-time", nullable: true}
    },
    required: [:operator_participant_id],
    additionalProperties: false
  })
end

defmodule DispatchWeb.Schemas.TripTransition do
  @moduledoc "Moves a trip."

  alias OpenApiSpex.Schema

  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "TripTransition",
    type: :object,
    properties: %{
      action: %Schema{type: :string, enum: ["activate", "complete", "cancel"]},
      expected_version: %Schema{type: :integer}
    },
    required: [:action, :expected_version],
    additionalProperties: false
  })
end
