defmodule DispatchWeb.Schemas.DeviceRegistrationRequest do
  @moduledoc "The body of `POST /v1/me/devices` (Section 23.1)."

  alias OpenApiSpex.Schema

  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "DeviceRegistrationRequest",
    type: :object,
    properties: %{
      installation_id: %Schema{
        type: :string,
        minLength: 1,
        maxLength: 200,
        description: "Stable per-installation identifier, chosen by the app."
      },
      public_key: %Schema{type: :string, description: "Base64url Ed25519 public key (32 bytes)."},
      proof: %Schema{
        type: :string,
        description:
          "Base64url Ed25519 signature by that key over the CoopEventCanonicalV1 encoding of " <>
            "{schema: \"DispatchDeviceRegistrationV1\", tenant_id, participant_id, " <>
            "installation_id, public_key (bytes)}, the tenant and participant being the caller's."
      }
    },
    required: [:installation_id, :public_key, :proof],
    additionalProperties: false
  })
end

defmodule DispatchWeb.Schemas.DeviceRegistration do
  @moduledoc "A registered device, as its own installation sees it."

  alias OpenApiSpex.Schema

  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "DeviceRegistration",
    type: :object,
    properties: %{
      device_id: %Schema{type: :string, format: :uuid},
      installation_id: %Schema{type: :string}
    },
    required: [:device_id, :installation_id],
    additionalProperties: false
  })
end
