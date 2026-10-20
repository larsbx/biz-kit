defmodule DispatchWeb.Schemas.RoleAssignmentChoice do
  @moduledoc """
  One role assignment a principal may select (Section 24.6).

  Identifier and label only. Section 4.3's switcher needs to name the choices;
  what each one permits is the capability document's business, and only for
  the assignment actually selected.
  """

  alias OpenApiSpex.Schema

  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "RoleAssignmentChoice",
    type: :object,
    properties: %{
      id: %Schema{type: :string, format: :uuid},
      label: %Schema{type: :string}
    },
    required: [:id, :label],
    additionalProperties: false
  })
end

defmodule DispatchWeb.Schemas.RoleAssignmentList do
  @moduledoc "The body of `GET /v1/me/role-assignments`."

  alias DispatchWeb.Schemas.RoleAssignmentChoice
  alias OpenApiSpex.Schema

  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "RoleAssignmentList",
    type: :object,
    properties: %{
      role_assignments: %Schema{type: :array, items: RoleAssignmentChoice}
    },
    required: [:role_assignments],
    additionalProperties: false
  })
end

defmodule DispatchWeb.Schemas.CapabilityDocumentResponse do
  @moduledoc """
  The body of `GET /v1/role-capabilities` (d-patch §23.2).

  `document` is the `CoopEventCanonicalV1` encoding of the claims and
  `signature` an Ed25519 signature over exactly those bytes. The client
  verifies the signature against its pinned key before decoding anything.
  """

  alias OpenApiSpex.Schema

  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "CapabilityDocumentResponse",
    type: :object,
    properties: %{
      document: %Schema{
        type: :string,
        description:
          "base64url CoopEventCanonicalV1 (CBOR) claims: schema " <>
            "(DispatchCapabilityDocumentV1), schema_version, sub, tenant_id, " <>
            "participant_id, role_assignment_id, role, capabilities, features, " <>
            "status_options, iat, exp."
      },
      signature: %Schema{type: :string, description: "base64url Ed25519 over the document bytes."},
      key_id: %Schema{
        type: :string,
        description: "`k-` and the signing key's first four bytes in hex."
      }
    },
    required: [:document, :signature, :key_id],
    additionalProperties: false
  })
end
