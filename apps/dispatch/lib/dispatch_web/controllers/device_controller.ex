defmodule DispatchWeb.DeviceController do
  @moduledoc """
  `POST /v1/me/devices`: the field app registers its installation's key after
  sign-in (Section 23.1; docs/architecture/2026-10-21-device-keys.md). The
  rules are `Dispatch.Accounts.DeviceKeys`'; this maps them to HTTP.
  """

  use Phoenix.Controller, formats: [:json]
  use OpenApiSpex.ControllerSpecs

  alias Dispatch.Accounts.DeviceKeys
  alias Dispatch.Idempotency
  alias DispatchWeb.Problem
  alias DispatchWeb.Schemas.{DeviceRegistration, DeviceRegistrationRequest}

  tags(["devices"])

  @problem {"Problem", "application/problem+json", DispatchWeb.Schemas.Problem}

  operation(:create,
    summary: "Register this installation's device key",
    description: """
    Self-service: the proof shows the caller's installation holds the key, and
    no one approves it. Registering the same key again returns the device. An
    installation registered with another key, or to someone else, is a
    conflict; a new installation is how a key changes.
    """,
    security: [%{"bearerAuth" => []}],
    parameters: [
      "idempotency-key": [
        in: :header,
        type: :string,
        description: "Replaying a mutation with the same key returns the stored response."
      ],
      "x-role-assignment-id": [
        in: :header,
        type: :string,
        description:
          "Selects which held role assignment the request acts under, when there are several. " <>
            "The device is the participant's, whichever is selected."
      ]
    ],
    request_body: {"Registration", "application/json", DeviceRegistrationRequest},
    responses: [
      created: {"Registered", "application/json", DeviceRegistration},
      ok: {"Already registered", "application/json", DeviceRegistration},
      unauthorized: @problem,
      conflict: @problem,
      unprocessable_entity: @problem
    ]
  )

  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, _params) do
    actor = conn.assigns.actor
    body = conn.body_params

    # Section 24: every mutation honours `Idempotency-Key`. A rejection rolls
    # back and releases the key, as for status declarations.
    Idempotency.execute(actor, idempotency_key(conn), body, fn ->
      case DeviceKeys.register(actor, body["installation_id"], body["public_key"], body["proof"]) do
        {:ok, outcome, device} ->
          {:ok, if(outcome == :created, do: 201, else: 200),
           %{device_id: device.id, installation_id: device.installation_id}}

        {:error, reason} ->
          {:error, reason}
      end
    end)
    |> then(&respond(conn, &1))
  end

  defp idempotency_key(conn) do
    case get_req_header(conn, "idempotency-key") do
      [key | _rest] -> key
      [] -> nil
    end
  end

  defp respond(conn, {:ok, status, body}), do: conn |> put_status(status) |> json(body)

  # A refusal from inside the idempotency ledger's transaction, which Ash
  # rolled back with its own changeset.
  defp respond(conn, {:error, %Ash.Changeset{} = rolled_back}),
    do: respond(conn, {:error, DeviceKeys.refusal(rolled_back)})

  defp respond(conn, {:error, reason}) do
    case reason do
      :installation_conflict ->
        Problem.send(
          conn,
          409,
          "INSTALLATION_CONFLICT",
          "This installation is registered with another key or to someone else."
        )

      :invalid_proof ->
        Problem.send(conn, 422, "PROOF_INVALID", "The proof does not verify under this key.")

      :key_reused ->
        Problem.send(
          conn,
          409,
          "IDEMPOTENCY_KEY_REUSED",
          "This idempotency key was used for a different request."
        )

      :in_progress ->
        Problem.send(
          conn,
          409,
          "IDEMPOTENCY_KEY_IN_PROGRESS",
          "An identical request is still being processed; retry shortly."
        )

      field ->
        Problem.send(conn, 422, "VALIDATION_FAILED", "#{field_name(field)} is not valid.")
    end
  end

  defp field_name(:invalid_installation_id), do: "installation_id"
  defp field_name(:invalid_public_key), do: "public_key"
  defp field_name(:invalid_registration), do: "The registration"
end
