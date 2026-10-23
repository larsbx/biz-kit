defmodule DispatchWeb.Schemas.LocationConsentRequest do
  @moduledoc "The body of `POST /v1/me/location-consents` (Section 25.3)."

  alias OpenApiSpex.Schema

  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "LocationConsentRequest",
    type: :object,
    properties: %{
      assignment_id: %Schema{
        type: :string,
        format: :uuid,
        description: "The caller's own planned or active assignment the consent covers."
      }
    },
    required: [:assignment_id],
    additionalProperties: false
  })
end

defmodule DispatchWeb.Schemas.LocationConsent do
  @moduledoc "A location-sharing consent grant, as its participant sees it."

  alias OpenApiSpex.Schema

  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "LocationConsent",
    type: :object,
    properties: %{
      consent_grant_id: %Schema{type: :string, format: :uuid},
      assignment_id: %Schema{type: :string, format: :uuid},
      granted_at: %Schema{type: :string, format: :"date-time"},
      expires_at: %Schema{
        type: :string,
        format: :"date-time",
        nullable: true,
        description: "The assignment's end plus its grace period; absent while it has no end."
      },
      revoked_at: %Schema{type: :string, format: :"date-time", nullable: true}
    },
    required: [:consent_grant_id, :assignment_id, :granted_at, :expires_at, :revoked_at],
    additionalProperties: false
  })
end

defmodule DispatchWeb.Schemas.LocationSampleItem do
  @moduledoc """
  One sample in a batch (Section 24.2). Coordinates and measurements are
  fixed-point integers, because the device signs the sample's fields in the
  canonical form, which has no floats.
  """

  alias OpenApiSpex.Schema

  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "LocationSampleItem",
    type: :object,
    properties: %{
      sample_id: %Schema{type: :string, format: :uuid, description: "Client-assigned (UUIDv7)."},
      assignment_id: %Schema{type: :string, format: :uuid},
      lat_e7: %Schema{type: :integer, minimum: -900_000_000, maximum: 900_000_000},
      lng_e7: %Schema{type: :integer, minimum: -1_800_000_000, maximum: 1_800_000_000},
      accuracy_cm: %Schema{type: :integer, minimum: 0, description: "Horizontal accuracy."},
      speed_cmps: %Schema{type: :integer, minimum: 0},
      bearing_cdeg: %Schema{type: :integer, minimum: 0, maximum: 36_000},
      provider: %Schema{type: :string, minLength: 1, maxLength: 32},
      is_mock: %Schema{type: :boolean},
      occurred_at: %Schema{type: :string, format: :"date-time", description: "Acquisition time."},
      device_id: %Schema{type: :string, format: :uuid},
      device_sequence: %Schema{type: :integer, minimum: 0},
      consent_grant_id: %Schema{type: :string, format: :uuid},
      device_signature: %Schema{
        type: :string,
        description:
          "Base64url Ed25519 signature by the device's registered key over the " <>
            "CoopEventCanonicalV1 encoding of this object's other fields plus " <>
            "schema: \"DispatchLocationSampleV1\"."
      }
    },
    required: [
      :sample_id,
      :assignment_id,
      :lat_e7,
      :lng_e7,
      :accuracy_cm,
      :provider,
      :is_mock,
      :occurred_at,
      :device_id,
      :device_sequence,
      :consent_grant_id,
      :device_signature
    ]
  })
end

defmodule DispatchWeb.Schemas.LocationSampleBatch do
  @moduledoc "The body of `POST /v1/me/location-samples:batch`: at most 100 samples."

  alias OpenApiSpex.Schema

  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "LocationSampleBatch",
    type: :object,
    properties: %{
      samples: %Schema{type: :array, items: DispatchWeb.Schemas.LocationSampleItem, maxItems: 100}
    },
    required: [:samples],
    additionalProperties: false
  })
end

defmodule DispatchWeb.Schemas.LocationSampleResults do
  @moduledoc "Section 24.2's `207`: one result per sample, in the order sent."

  alias OpenApiSpex.Schema

  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "LocationSampleResults",
    type: :object,
    properties: %{
      results: %Schema{
        type: :array,
        items: %Schema{
          type: :object,
          properties: %{
            sample_id: %Schema{type: :string, nullable: true},
            result: %Schema{type: :string, enum: ["ACCEPTED", "DUPLICATE", "REJECTED"]},
            code: %Schema{
              type: :string,
              nullable: true,
              description:
                "Why a sample was rejected: REJECTED_CONSENT, CLOCK_SKEW, INVALID_SAMPLE, " <>
                  "DEVICE_SIGNATURE_REQUIRED, DEVICE_SIGNATURE_INVALID or DEVICE_SEQUENCE_CONFLICT."
            }
          },
          required: [:sample_id, :result, :code]
        }
      }
    },
    required: [:results],
    additionalProperties: false
  })
end

defmodule DispatchWeb.Schemas.LocationDemandPolicy do
  @moduledoc """
  The `data` of a `location-demand` event on `GET /v1/me/location-demand`:
  how often the device samples and uploads until the next event.
  """

  alias OpenApiSpex.Schema

  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "LocationDemandPolicy",
    type: :object,
    properties: %{
      mode: %Schema{
        type: :string,
        enum: ["realtime", "trickle"],
        description: "`realtime` while someone entitled to the position is watching it."
      },
      sample_interval_ms: %Schema{type: :integer, minimum: 0},
      upload_interval_ms: %Schema{
        type: :integer,
        minimum: 0,
        description: "`0`: upload each sample as soon as it is acquired."
      }
    },
    required: [:mode, :sample_interval_ms, :upload_interval_ms],
    additionalProperties: false
  })
end
