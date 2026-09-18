defmodule DispatchWeb.Schemas.HealthCheck do
  @moduledoc "One named dependency check inside a readiness response."

  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "HealthCheck",
    type: :object,
    properties: %{
      status: %OpenApiSpex.Schema{type: :string, enum: ["ok", "error"]},
      detail: %OpenApiSpex.Schema{type: :string, description: "Stable reason code when failing"},
      postgis_version: %OpenApiSpex.Schema{type: :string},
      pending: %OpenApiSpex.Schema{type: :integer}
    },
    required: [:status],
    additionalProperties: false
  })
end

defmodule DispatchWeb.Schemas.LivenessResponse do
  @moduledoc "Process liveness. Asserts nothing about dependencies (Section 32)."

  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "LivenessResponse",
    type: :object,
    properties: %{
      status: %OpenApiSpex.Schema{type: :string, enum: ["ok"]},
      checked_at: %OpenApiSpex.Schema{type: :string, format: :"date-time"}
    },
    required: [:status, :checked_at],
    additionalProperties: false
  })
end

defmodule DispatchWeb.Schemas.ReadinessResponse do
  @moduledoc "Database and migration state. Makes no outbound provider call."

  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "ReadinessResponse",
    type: :object,
    properties: %{
      status: %OpenApiSpex.Schema{type: :string, enum: ["ok", "unready"]},
      checked_at: %OpenApiSpex.Schema{type: :string, format: :"date-time"},
      checks: %OpenApiSpex.Schema{
        type: :object,
        additionalProperties: DispatchWeb.Schemas.HealthCheck
      }
    },
    required: [:status, :checked_at, :checks],
    additionalProperties: false
  })
end

defmodule DispatchWeb.Schemas.DependenciesResponse do
  @moduledoc """
  Redacted adapter-configuration report.

  Section 31 permits configuration keys and redacted presence, never values, so
  `required_secrets` maps a variable name to a boolean and never to its content.
  """

  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "DependenciesResponse",
    type: :object,
    properties: %{
      status: %OpenApiSpex.Schema{type: :string, enum: ["ok"]},
      checked_at: %OpenApiSpex.Schema{type: :string, format: :"date-time"},
      adapters: %OpenApiSpex.Schema{
        type: :object,
        properties: %{
          ports: %OpenApiSpex.Schema{type: :object, additionalProperties: true},
          required_secrets: %OpenApiSpex.Schema{
            type: :object,
            additionalProperties: %OpenApiSpex.Schema{type: :boolean},
            description: "Presence only; values are never reported."
          }
        },
        required: [:ports, :required_secrets]
      }
    },
    required: [:status, :checked_at, :adapters],
    additionalProperties: false
  })
end

defmodule DispatchWeb.Schemas.Problem do
  @moduledoc "RFC 9457 Problem Details (Section 19.2)."

  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "Problem",
    type: :object,
    properties: %{
      type: %OpenApiSpex.Schema{type: :string, format: :uri},
      title: %OpenApiSpex.Schema{type: :string},
      status: %OpenApiSpex.Schema{type: :integer},
      detail: %OpenApiSpex.Schema{type: :string},
      instance: %OpenApiSpex.Schema{type: :string},
      code: %OpenApiSpex.Schema{type: :string, description: "Stable non-sensitive reason code"},
      correlation_id: %OpenApiSpex.Schema{type: :string}
    },
    required: [:type, :title, :status, :detail, :instance, :code, :correlation_id],
    additionalProperties: false
  })
end
