defmodule DispatchWeb.Schemas.PartnerSubmission do
  @moduledoc "Nonbinding partner input. Identity and authority are server derived."
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "PartnerSubmission",
    type: :object,
    properties: %{
      stop_id: %Schema{type: :string, format: :uuid},
      expected_version: %Schema{type: :integer, minimum: 0},
      expected_latest_id: %Schema{type: :string, format: :uuid, nullable: true},
      correlation_id: %Schema{type: :string, format: :uuid},
      state: %Schema{type: :string, enum: ~w(NOT_READY READY CHECKED_IN BLOCKED)},
      note: %Schema{type: :string, maxLength: 2000},
      occurred_at: %Schema{type: :string, format: :"date-time"},
      kind: %Schema{type: :string, enum: ~w(APPOINTMENT INSTRUCTION)},
      window_start: %Schema{type: :string, format: :"date-time"},
      window_end: %Schema{type: :string, format: :"date-time"},
      instructions: %Schema{type: :string, maxLength: 2000},
      expires_at: %Schema{type: :string, format: :"date-time"},
      category: %Schema{type: :string, enum: ~w(PICKUP_DOCUMENT PROOF_OF_DELIVERY)},
      label: %Schema{type: :string, maxLength: 200},
      reference: %Schema{
        type: :string,
        maxLength: 500,
        description: "Opaque proof locator; encrypted at rest. No URL, upload or download."
      }
    },
    required: [:expected_version],
    additionalProperties: false
  })
end

defmodule DispatchWeb.Schemas.PartnerReceipt do
  @moduledoc "Acknowledgment of an attributed contribution, never an execution receipt."
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "PartnerReceipt",
    type: :object,
    properties: %{
      id: %Schema{type: :string, format: :uuid},
      stop_id: %Schema{type: :string, format: :uuid},
      source: %Schema{type: :string, enum: ["PARTICIPANT"]},
      recorded_at: %Schema{type: :string, format: :"date-time"}
    },
    required: [:id, :stop_id, :source, :recorded_at],
    additionalProperties: false
  })
end

defmodule DispatchWeb.Schemas.PartnerReadinessRequest do
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "PartnerReadinessRequest",
    type: :object,
    properties:
      Map.take(
        DispatchWeb.Schemas.PartnerSubmission.schema().properties,
        [:state, :note, :occurred_at, :correlation_id, :expected_version, :expected_latest_id]
      ),
    required: [:state, :expected_version],
    additionalProperties: false
  })
end

defmodule DispatchWeb.Schemas.PartnerReferenceRequest do
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "PartnerReferenceRequest",
    type: :object,
    properties:
      Map.take(
        DispatchWeb.Schemas.PartnerSubmission.schema().properties,
        [:category, :label, :reference, :correlation_id, :expected_version]
      ),
    required: [:category, :label, :reference, :expected_version],
    additionalProperties: false
  })
end

defmodule DispatchWeb.Schemas.PartnerProposalRequest do
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "PartnerProposalRequest",
    type: :object,
    properties:
      Map.take(
        DispatchWeb.Schemas.PartnerSubmission.schema().properties,
        [
          :stop_id,
          :kind,
          :window_start,
          :window_end,
          :instructions,
          :expires_at,
          :correlation_id,
          :expected_version
        ]
      ),
    required: [:stop_id, :kind, :expires_at, :expected_version],
    additionalProperties: false,
    oneOf: [
      %Schema{
        properties: %{kind: %Schema{type: :string, enum: ["APPOINTMENT"]}},
        required: [:window_start, :window_end]
      },
      %Schema{
        properties: %{kind: %Schema{type: :string, enum: ["INSTRUCTION"]}},
        required: [:instructions]
      }
    ]
  })
end
