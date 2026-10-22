defmodule DispatchWeb.LocationController do
  @moduledoc """
  Consented location sharing over `/v1` (Sections 24.2, 25.3). The rules are
  `Dispatch.Operations.Locations`'; this maps them to HTTP, and runs each
  mutation under its `Idempotency-Key`.
  """

  use Phoenix.Controller, formats: [:json]
  use OpenApiSpex.ControllerSpecs

  alias Dispatch.Idempotency
  alias Dispatch.Operations.Locations
  alias DispatchWeb.Problem

  alias DispatchWeb.Schemas.{
    LocationConsent,
    LocationConsentRequest,
    LocationSampleBatch,
    LocationSampleResults
  }

  tags(["location"])

  # Section 24.2: 256 KiB uncompressed per batch.
  @max_batch_bytes 262_144

  @problem {"Problem", "application/problem+json", DispatchWeb.Schemas.Problem}
  @headers [
    "idempotency-key": [
      in: :header,
      type: :string,
      description: "Replaying a mutation with the same key returns the stored response."
    ],
    "x-role-assignment-id": [
      in: :header,
      type: :string,
      description: "Selects which held role assignment the request acts under."
    ]
  ]

  operation(:begin_consent,
    summary: "Begin sharing location for one of your assignments",
    security: [%{"bearerAuth" => []}],
    parameters: @headers,
    request_body: {"Consent", "application/json", LocationConsentRequest},
    responses: [
      created: {"Consent granted", "application/json", LocationConsent},
      forbidden: @problem,
      not_found: @problem
    ]
  )

  operation(:revoke_consent,
    summary: "Stop sharing location",
    description: "Samples acquired before revocation are still accepted when uploaded later.",
    security: [%{"bearerAuth" => []}],
    parameters: [{:consent_id, [in: :path, type: :string, required: true]} | @headers],
    responses: [ok: {"Revoked", "application/json", LocationConsent}, not_found: @problem]
  )

  operation(:ingest,
    summary: "Upload location samples",
    description: """
    One result per sample, in the order sent (`207`). A sample acquired under a
    consent revoked since is accepted; one acquired after is REJECTED_CONSENT.
    """,
    security: [%{"bearerAuth" => []}],
    parameters: @headers,
    request_body: {"Samples", "application/json", LocationSampleBatch},
    responses: [
      multi_status: {"Results", "application/json", LocationSampleResults},
      forbidden: @problem,
      request_entity_too_large: @problem
    ]
  )

  operation(:ingest_driver,
    summary: "Upload location samples (DRIVER compatibility projection)",
    description: "Section 24.2's DRIVER route. Identical behaviour to /v1/me.",
    security: [%{"bearerAuth" => []}],
    parameters: @headers,
    request_body: {"Samples", "application/json", LocationSampleBatch},
    responses: [
      multi_status: {"Results", "application/json", LocationSampleResults},
      forbidden: @problem,
      request_entity_too_large: @problem
    ]
  )

  @spec begin_consent(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def begin_consent(conn, _params) do
    mutate(conn, fn actor ->
      with {:ok, grant} <- Locations.begin_consent(actor, conn.body_params["assignment_id"]),
           do: {:ok, 201, consent(grant)}
    end)
  end

  @spec revoke_consent(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def revoke_consent(conn, %{"consent_id" => id}) do
    mutate(conn, fn actor ->
      with {:ok, grant} <- Locations.revoke_consent(actor, id), do: {:ok, 200, consent(grant)}
    end)
  end

  @spec ingest(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def ingest(conn, params), do: batch(conn, params)

  @spec ingest_driver(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def ingest_driver(conn, params), do: batch(conn, params)

  # The router matches `location-samples:batch` with `:batch` as a parameter;
  # only the custom method itself is this route.
  defp batch(conn, %{"batch" => ":batch"}) do
    cond do
      too_large?(conn) ->
        refused(conn, :batch_too_large)

      not is_list(conn.body_params["samples"]) ->
        Problem.send(conn, 400, "MALFORMED_REQUEST", "samples must be a list.")

      true ->
        mutate(conn, fn actor ->
          with {:ok, results} <- Locations.ingest(actor, conn.body_params["samples"]),
               do: {:ok, 207, %{results: results}}
        end)
    end
  end

  defp batch(conn, _not_this_route), do: Problem.send(conn, 404, "NOT_FOUND", "Not found.")

  defp too_large?(conn) do
    case get_req_header(conn, "content-length") do
      [length | _] -> String.to_integer(length) > @max_batch_bytes
      [] -> false
    end
  rescue
    ArgumentError -> true
  end

  defp mutate(conn, fun) do
    actor = conn.assigns.actor

    actor
    |> Idempotency.execute(idempotency_key(conn), conn.body_params, fn -> fun.(actor) end)
    |> case do
      {:ok, status, body} -> conn |> put_status(status) |> json(body)
      {:error, reason} -> refused(conn, reason)
    end
  end

  defp idempotency_key(conn) do
    case get_req_header(conn, "idempotency-key") do
      [key | _rest] -> key
      [] -> nil
    end
  end

  defp consent(grant) do
    %{
      consent_grant_id: grant.id,
      assignment_id: grant.scope_json["assignment_id"],
      granted_at: grant.granted_at,
      expires_at: grant.expires_at,
      revoked_at: grant.revoked_at
    }
  end

  defp refused(conn, :forbidden),
    do: Problem.send(conn, 403, "FORBIDDEN", "This role assignment cannot share location.")

  defp refused(conn, :not_found), do: Problem.send(conn, 404, "NOT_FOUND", "Not found.")

  defp refused(conn, :batch_too_large),
    do:
      Problem.send(
        conn,
        413,
        "BATCH_TOO_LARGE",
        "A batch carries at most #{Locations.max_batch()} samples and 256 KiB."
      )

  defp refused(conn, :key_reused),
    do:
      Problem.send(
        conn,
        409,
        "IDEMPOTENCY_KEY_REUSED",
        "This idempotency key was used for a different request."
      )

  defp refused(conn, :in_progress),
    do:
      Problem.send(
        conn,
        409,
        "IDEMPOTENCY_KEY_IN_PROGRESS",
        "An identical request is still being processed; retry shortly."
      )
end
