defmodule DispatchWeb.PartnerApiController do
  @moduledoc "The Section 24.6 machine contract; the same domain actions as the portal."
  use Phoenix.Controller, formats: [:json]
  use OpenApiSpex.ControllerSpecs
  alias DispatchWeb.PartnerActionController, as: Actions

  alias DispatchWeb.Schemas.{
    PartnerReadinessRequest,
    PartnerReferenceRequest,
    PartnerProposalRequest,
    PartnerReceipt
  }

  tags(["partners"])
  @problem {"Problem", "application/problem+json", DispatchWeb.Schemas.Problem}

  operation(:readiness,
    summary: "Report readiness",
    description:
      "Selected assignment plus active party relationship. A current expected_version and Idempotency-Key are required. Readiness compares expected_latest_id. Proposals require stop_id, kind, expiry and a window or instructions; they never confirm or execute. Actor, tenant, approval and execution fields are rejected.",
    security: [%{"bearerAuth" => []}],
    parameters: [
      stop_id: [in: :path, type: :string, required: true],
      "idempotency-key": [in: :header, type: :string, required: true],
      "x-role-assignment-id": [in: :header, type: :string]
    ],
    request_body: {"Contribution", "application/json", PartnerReadinessRequest},
    responses: [
      created: {"Stored", "application/json", PartnerReceipt},
      not_found: @problem,
      conflict: @problem,
      unprocessable_entity: @problem,
      bad_request: @problem,
      unauthorized: @problem
    ]
  )

  operation(:document,
    summary: "Add an encrypted proof reference",
    description:
      "Selected assignment plus active party relationship. A current expected_version and Idempotency-Key are required. Readiness compares expected_latest_id. Proposals require stop_id, kind, expiry and a window or instructions; they never confirm or execute. Actor, tenant, approval and execution fields are rejected.",
    security: [%{"bearerAuth" => []}],
    parameters: [
      stop_id: [in: :path, type: :string, required: true],
      "idempotency-key": [in: :header, type: :string, required: true],
      "x-role-assignment-id": [in: :header, type: :string]
    ],
    request_body: {"Contribution", "application/json", PartnerReferenceRequest},
    responses: [
      created: {"Stored", "application/json", PartnerReceipt},
      not_found: @problem,
      conflict: @problem,
      unprocessable_entity: @problem,
      bad_request: @problem,
      unauthorized: @problem
    ]
  )

  operation(:proposal,
    summary: "Submit a nonbinding proposal",
    description:
      "Selected assignment plus active party relationship. A current expected_version and Idempotency-Key are required. Readiness compares expected_latest_id. Proposals require stop_id, kind, expiry and a window or instructions; they never confirm or execute. Actor, tenant, approval and execution fields are rejected.",
    security: [%{"bearerAuth" => []}],
    parameters: [
      "idempotency-key": [in: :header, type: :string, required: true],
      "x-role-assignment-id": [in: :header, type: :string]
    ],
    request_body: {"Contribution", "application/json", PartnerProposalRequest},
    responses: [
      created: {"Stored", "application/json", PartnerReceipt},
      not_found: @problem,
      conflict: @problem,
      unprocessable_entity: @problem,
      bad_request: @problem,
      unauthorized: @problem
    ]
  )

  operation(:stop,
    summary: "Read the authorized partner projection",
    security: [%{"bearerAuth" => []}],
    parameters: [
      stop_id: [in: :path, type: :string, required: true],
      "x-role-assignment-id": [in: :header, type: :string]
    ],
    responses: [
      ok: {"Projection", "application/json", %OpenApiSpex.Schema{type: :object}},
      not_found: @problem,
      unauthorized: @problem
    ]
  )

  operation(:load,
    summary: "Read the authorized partner projection",
    security: [%{"bearerAuth" => []}],
    parameters: [
      load_id: [in: :path, type: :string, required: true],
      "x-role-assignment-id": [in: :header, type: :string]
    ],
    responses: [
      ok: {"Projection", "application/json", %OpenApiSpex.Schema{type: :object}},
      not_found: @problem,
      unauthorized: @problem
    ]
  )

  defdelegate readiness(conn, params), to: Actions
  defdelegate document(conn, params), to: Actions
  defdelegate proposal(conn, params), to: Actions
  defdelegate stop(conn, params), to: Actions
  defdelegate load(conn, params), to: Actions
end
