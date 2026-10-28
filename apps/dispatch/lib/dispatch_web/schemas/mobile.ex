defmodule DispatchWeb.Schemas.MobileAuthorizeRequest do
  @moduledoc false
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "MobileAuthorizeRequest",
    type: :object,
    properties: %{code_challenge: %Schema{type: :string}, state: %Schema{type: :string}},
    required: [:code_challenge, :state],
    additionalProperties: false
  })
end

defmodule DispatchWeb.Schemas.MobileAuthorizeResponse do
  @moduledoc false
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "MobileAuthorizeResponse",
    type: :object,
    properties: %{authorization_url: %Schema{type: :string}},
    required: [:authorization_url],
    additionalProperties: false
  })
end

defmodule DispatchWeb.Schemas.MobileTokenRequest do
  @moduledoc false
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "MobileTokenRequest",
    type: :object,
    properties: %{code: %Schema{type: :string}, code_verifier: %Schema{type: :string}},
    required: [:code, :code_verifier],
    additionalProperties: false
  })
end

defmodule DispatchWeb.Schemas.MobileTokenResponse do
  @moduledoc false
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "MobileTokenResponse",
    type: :object,
    properties: %{
      access_token: %Schema{type: :string},
      token_type: %Schema{type: :string},
      subject: %Schema{type: :string},
      principal: %Schema{type: :string},
      expires_at: %Schema{type: :integer}
    },
    required: [:access_token, :token_type, :subject, :principal, :expires_at],
    additionalProperties: false
  })
end

defmodule DispatchWeb.Schemas.MobileEnrolmentRequest do
  @moduledoc false
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "MobileEnrolmentRequest",
    type: :object,
    properties: %{
      key_id: %Schema{type: :string},
      public_key: %Schema{type: :string},
      label: %Schema{type: :string}
    },
    required: [:key_id, :public_key, :label],
    additionalProperties: false
  })
end

defmodule DispatchWeb.Schemas.MobileChallengeResponse do
  @moduledoc false
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "MobileChallengeResponse",
    type: :object,
    properties: %{id: %Schema{type: :string}, statement: %Schema{type: :string}},
    required: [:id, :statement],
    additionalProperties: false
  })
end

defmodule DispatchWeb.Schemas.MobileProofRequest do
  @moduledoc false
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "MobileProofRequest",
    type: :object,
    properties: %{signature: %Schema{type: :string}},
    required: [:signature],
    additionalProperties: false
  })
end

defmodule DispatchWeb.Schemas.MobileCodeResponse do
  @moduledoc false
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "MobileCodeResponse",
    type: :object,
    properties: %{code: %Schema{type: :string}, expires_at: %Schema{type: :integer}},
    required: [:code, :expires_at],
    additionalProperties: false
  })
end

defmodule DispatchWeb.Schemas.MobileRegisterRequest do
  @moduledoc false
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "MobileRegisterRequest",
    type: :object,
    properties: %{
      key_id: %Schema{type: :string},
      public_key: %Schema{type: :string},
      installation_id: %Schema{type: :string}
    },
    required: [:key_id, :public_key, :installation_id],
    additionalProperties: false
  })
end

defmodule DispatchWeb.Schemas.MobileDeviceResponse do
  @moduledoc false
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "MobileDeviceResponse",
    type: :object,
    properties: %{device_id: %Schema{type: :string}},
    required: [:device_id],
    additionalProperties: false
  })
end
