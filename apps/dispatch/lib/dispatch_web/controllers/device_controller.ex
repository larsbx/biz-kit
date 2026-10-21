defmodule DispatchWeb.DeviceController do
  @moduledoc """
  `POST /v1/me/devices`: the field app registers its installation's key after
  sign-in (Section 23.1; docs/architecture/2026-10-21-device-keys.md). The
  rules are `Dispatch.Accounts.DeviceKeys`'; this maps them to HTTP.
  """

  use Phoenix.Controller, formats: [:json]
  use OpenApiSpex.ControllerSpecs

  alias Dispatch.Accounts.DeviceKeys
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
  def create(conn, params) do
    case DeviceKeys.register(
           conn.assigns.actor,
           params["installation_id"],
           params["public_key"],
           params["proof"]
         ) do
      {:ok, outcome, device} ->
        conn
        |> put_status(if outcome == :created, do: 201, else: 200)
        |> json(%{device_id: device.id, installation_id: device.installation_id})

      {:error, :installation_conflict} ->
        Problem.send(
          conn,
          409,
          "INSTALLATION_CONFLICT",
          "This installation is registered with another key or to someone else."
        )

      {:error, :invalid_proof} ->
        Problem.send(conn, 422, "PROOF_INVALID", "The proof does not verify under this key.")

      {:error, field} ->
        Problem.send(conn, 422, "VALIDATION_FAILED", "#{field_name(field)} is not valid.")
    end
  end

  defp field_name(:invalid_installation_id), do: "installation_id"
  defp field_name(:invalid_public_key), do: "public_key"
end
