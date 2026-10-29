defmodule DispatchWeb.RoleCapabilityController do
  @moduledoc """
  The two reads the field application needs before it can show a role's
  surfaces (Sections 23.2, 24.6).

  - `GET /v1/me/role-assignments` — which assignments this principal may
    select. It runs *before* an assignment is selected, so it sits behind
    authentication alone.
  - `GET /v1/role-capabilities` — the signed capability document for the one
    assignment the request acts under.
  """

  use Phoenix.Controller, formats: [:json]
  use OpenApiSpex.ControllerSpecs

  alias Dispatch.Access.{CapabilityDocument, CapabilitySigner}
  alias Dispatch.Identity.PrincipalResolution
  alias DispatchWeb.Problem
  alias DispatchWeb.Schemas.{CapabilityDocumentResponse, RoleAssignmentList}

  tags(["roles"])

  @problem {"Problem", "application/problem+json", DispatchWeb.Schemas.Problem}

  operation(:assignments,
    summary: "List the role assignments this principal may act under",
    description: """
    Identifiers and labels only. Choose one and send it as
    `X-Role-Assignment-ID`; the choice selects authority context, it never
    grants it.
    """,
    security: [%{"bearerAuth" => []}, %{"nativeSession" => []}],
    responses: [
      ok: {"Selectable assignments", "application/json", RoleAssignmentList},
      unauthorized: @problem
    ]
  )

  operation(:capabilities,
    summary: "The signed capability document for the selected role assignment",
    description: """
    Features are enabled from this document, never from a role key. It governs
    what the client offers; every request is still authorized by the server.
    """,
    security: [%{"bearerAuth" => []}, %{"nativeSession" => []}],
    parameters: [
      "x-role-assignment-id": [
        in: :header,
        type: :string,
        description: "Selects which held role assignment the document describes."
      ]
    ],
    responses: [
      ok: {"Signed document", "application/json", CapabilityDocumentResponse},
      unauthorized: @problem,
      forbidden: @problem,
      service_unavailable: @problem
    ]
  )

  @doc "Section 24.6's `GET /v1/me/role-assignments`."
  @spec assignments(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def assignments(conn, _params) do
    json(conn, %{
      role_assignments: PrincipalResolution.selectable(conn.assigns.oidc_claims.subject)
    })
  end

  @doc "Section 24.6's `GET /v1/role-capabilities`."
  @spec capabilities(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def capabilities(conn, _params) do
    claims = CapabilityDocument.claims(conn.assigns.actor, conn.assigns.oidc_claims.subject)

    with {:ok, key} <- CapabilitySigner.key(),
         {:ok, signed} <- CapabilitySigner.sign(claims, key) do
      json(conn, signed)
    else
      # Production refuses to start without a usable seed, so this is
      # configuration lost under a running node, or claims the canonical
      # profile cannot encode. An unsigned document is not a degraded answer
      # but a forgeable one, so there is none.
      {:error, _reason} ->
        Problem.send(
          conn,
          503,
          "CAPABILITY_SIGNING_UNAVAILABLE",
          "The capability document cannot be signed right now; retry later."
        )
    end
  end
end
