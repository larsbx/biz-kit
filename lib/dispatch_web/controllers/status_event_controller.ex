defmodule DispatchWeb.StatusEventController do
  @moduledoc """
  Participant status ingestion (Section 24.1).

  Two routes, one behaviour:

  - `POST /v1/me/status-events` — canonical, for any self-service profile.
  - `POST /v1/driver/status-events` — the `DRIVER` compatibility projection.

  Section 24.1 requires both to "invoke the same Ash action with the
  authenticated `participant_id` and active `role_assignment_id`". They are the
  same function clause here, differing only in the route that reaches it, so
  there is no second implementation that could drift.

  Section 21.1 confines a controller to transport: parsing the body, mapping a
  domain outcome to a status code. Everything else is
  `Dispatch.Operations.Declarations`.
  """

  use Phoenix.Controller, formats: [:json]
  use OpenApiSpex.ControllerSpecs

  alias Dispatch.Idempotency
  alias Dispatch.Operations.Declarations
  alias DispatchWeb.Problem
  alias DispatchWeb.Schemas.{StatusEventRequest, StatusEventResponse}

  tags(["status"])

  # Section 24 has every mutation accept `Idempotency-Key`, and Section 24.6 has
  # machine requests send `X-Role-Assignment-ID`. Declared here because the
  # Android client is generated from this contract (Section 20): a header the
  # description omits is a header the generated client cannot send.
  @headers [
    "idempotency-key": [
      in: :header,
      type: :string,
      description: "Replaying a mutation with the same key returns the stored response."
    ],
    "x-role-assignment-id": [
      in: :header,
      type: :string,
      description:
        "Selects which held role assignment the request acts under. " <>
          "It selects authority context; it never grants it."
    ]
  ]

  @responses [
    created: {"Stored declaration", "application/json", StatusEventResponse},
    bad_request: {"Malformed request", "application/problem+json", DispatchWeb.Schemas.Problem},
    unauthorized: {"Unauthenticated", "application/problem+json", DispatchWeb.Schemas.Problem},
    forbidden: {"Not permitted", "application/problem+json", DispatchWeb.Schemas.Problem},
    conflict: {"Conflicting reuse", "application/problem+json", DispatchWeb.Schemas.Problem},
    unprocessable_entity:
      {"Validation failed", "application/problem+json", DispatchWeb.Schemas.Problem}
  ]

  operation(:create,
    summary: "Declare a participant status",
    description: """
    Records a self-declared status for the authenticated participant. The
    participant is derived from the token and the active role assignment; it is
    not a parameter.
    """,
    security: [%{"bearerAuth" => []}],
    parameters: @headers,
    request_body: {"Declaration", "application/json", StatusEventRequest},
    responses: @responses
  )

  operation(:create_driver,
    summary: "Declare a driver status (compatibility projection)",
    description: "Section 24.1's DRIVER compatibility route. Identical behaviour to /v1/me.",
    security: [%{"bearerAuth" => []}],
    parameters: @headers,
    request_body: {"Declaration", "application/json", StatusEventRequest},
    responses: @responses
  )

  @doc "Canonical self-service declaration route."
  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, params), do: declare(conn, params)

  @doc "The DRIVER compatibility projection of `create/2`. Same behaviour, same events."
  @spec create_driver(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create_driver(conn, params), do: declare(conn, params)

  defp declare(conn, params) do
    with {:ok, attrs} <- parse(params) do
      with_idempotency(conn, params, fn -> record(conn, attrs) end)
    else
      {:error, field} ->
        Problem.send(conn, 400, "MALFORMED_REQUEST", "#{field} is not a valid value.")
    end
  end

  # Section 24: the key is optional, and a request without one simply executes.
  # The ledger is not a way to make clients send keys; it is a way to honour the
  # ones that do.
  defp with_idempotency(conn, params, run) do
    case get_req_header(conn, "idempotency-key") do
      [] ->
        run.()

      [key | _rest] ->
        case Idempotency.claim(conn.assigns.actor, key, params) do
          {:proceed, claim_id} -> settle(conn, claim_id, run)
          {:replay, status, body} -> conn |> put_status(status) |> json(body)
          {:error, :key_reused} -> reused(conn)
          {:error, :in_progress} -> in_progress(conn)
        end
    end
  end

  # Only a stored *response* is replayable, so a rejection releases the key and
  # the client's corrected retry is allowed to use it. Storing failures would
  # make a transient error permanent for twenty-four hours.
  defp settle(_conn, claim_id, run) do
    conn = run.()

    case conn.status do
      status when status in 200..299 ->
        Idempotency.complete(claim_id, status, Jason.decode!(conn.resp_body))
        conn

      _rejected ->
        Idempotency.abandon(claim_id)
        conn
    end
  end

  defp record(conn, attrs) do
    case Declarations.declare(conn.assigns.actor, attrs) do
      {:ok, _created_or_duplicate, event} ->
        conn |> put_status(:created) |> json(body(conn, event))

      {:error, :device_sequence_conflict} ->
        Problem.send(
          conn,
          409,
          "DEVICE_SEQUENCE_CONFLICT",
          "This device sequence already carries a different declaration."
        )

      {:error, %Ash.Error.Forbidden{}} ->
        Problem.send(conn, 403, "FORBIDDEN", "This role assignment cannot declare a status.")

      {:error, error} ->
        Problem.send(conn, 422, "VALIDATION_FAILED", validation_detail(error))
    end
  end

  defp reused(conn) do
    Problem.send(
      conn,
      409,
      "IDEMPOTENCY_KEY_REUSED",
      "This idempotency key was used for a different request."
    )
  end

  defp in_progress(conn) do
    Problem.send(
      conn,
      409,
      "IDEMPOTENCY_KEY_IN_PROGRESS",
      "An identical request is still being processed; retry shortly."
    )
  end

  # Section 24.1's `201` body: the stored event and the resulting status. A
  # duplicate returns the original event, which is what makes it the *original*
  # `201` body rather than a second one that merely looks alike.
  defp body(conn, event) do
    %{
      event: %{
        id: event.id,
        participant_id: event.participant_id,
        role_assignment_id: event.role_assignment_id,
        assignment_id: event.assignment_id,
        status: event.status,
        source: event.source,
        occurred_at: event.occurred_at,
        recorded_at: event.recorded_at,
        note: event.note,
        location_sample_id: event.location_sample_id,
        verification: event.verification,
        supersedes_event_id: event.supersedes_event_id,
        device_id: event.device_id,
        device_sequence: event.device_sequence
      },
      current_status: current_status(conn, event)
    }
  end

  # "Current" is the latest by `occurred_at`, which need not be the event just
  # written: an offline declaration uploaded late does not supersede a newer one
  # already recorded. Reading it back rather than echoing the input is what
  # keeps that true.
  defp current_status(conn, event) do
    actor = conn.assigns.actor

    latest =
      case Dispatch.Operations.ParticipantStatusEvent.current(event.participant_id,
             actor: actor,
             tenant: actor.tenant_id
           ) do
        {:ok, %{} = current} -> current
        _unavailable -> event
      end

    %{
      value: latest.status,
      source: latest.source,
      role_key: actor.role_assignment.role_definition.key,
      occurred_at: latest.occurred_at
    }
  end

  defp parse(params) do
    with {:ok, occurred_at} <- timestamp(params["occurred_at"]),
         {:ok, sequence} <- integer(params["device_sequence"]) do
      {:ok,
       %{
         status: params["status"],
         occurred_at: occurred_at,
         note: params["note"],
         assignment_id: params["assignment_id"],
         location_sample_id: params["location_sample_id"],
         supersedes_event_id: params["supersedes_event_id"],
         device_id: params["device_id"],
         device_sequence: sequence
       }}
    end
  end

  # Section 19.2 fixes RFC 3339 at the API boundary, so an unparseable timestamp
  # is a malformed request rather than something to coerce.
  defp timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _offset} -> {:ok, at}
      {:error, _reason} -> {:error, "occurred_at"}
    end
  end

  defp timestamp(_missing), do: {:error, "occurred_at"}

  defp integer(nil), do: {:ok, nil}
  defp integer(value) when is_integer(value), do: {:ok, value}
  defp integer(_value), do: {:error, "device_sequence"}

  defp validation_detail(%{errors: errors}) when is_list(errors) and errors != [] do
    errors
    |> Enum.map_join("; ", &Exception.message/1)
    |> String.slice(0, 500)
  end

  defp validation_detail(_error), do: "The declaration was rejected."
end
