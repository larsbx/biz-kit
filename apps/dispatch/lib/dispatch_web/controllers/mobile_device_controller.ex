defmodule DispatchWeb.MobileDeviceController do
  @moduledoc "Transport for existing CoopSubstrate device enrolment and Dispatch registration."
  use Phoenix.Controller, formats: [:json]
  use OpenApiSpex.ControllerSpecs

  operation(:request,
    summary: "Request governance-approved device enrolment",
    security: [%{"nativeSession" => []}],
    parameters: ["x-role-assignment-id": [in: :header, type: :string, required: true]],
    request_body: {"Request", "application/json", DispatchWeb.Schemas.MobileEnrolmentRequest},
    responses: [
      created: {"Response", "application/json", DispatchWeb.Schemas.MobileChallengeResponse},
      unauthorized: {"Unauthenticated", "application/problem+json", DispatchWeb.Schemas.Problem},
      forbidden: {"Rejected", "application/problem+json", DispatchWeb.Schemas.Problem}
    ]
  )

  operation(:prove,
    summary: "Prove possession of the requested key",
    security: [%{"nativeSession" => []}],
    parameters: [
      "x-role-assignment-id": [in: :header, type: :string, required: true],
      id: [in: :path, type: :string, required: true]
    ],
    request_body: {"Request", "application/json", DispatchWeb.Schemas.MobileProofRequest},
    responses: [
      created: {"Response", "application/json", DispatchWeb.Schemas.MobileCodeResponse},
      unauthorized: {"Unauthenticated", "application/problem+json", DispatchWeb.Schemas.Problem},
      forbidden: {"Rejected", "application/problem+json", DispatchWeb.Schemas.Problem}
    ]
  )

  operation(:register,
    summary: "Register an approved installation",
    security: [%{"nativeSession" => []}],
    parameters: ["x-role-assignment-id": [in: :header, type: :string, required: true]],
    request_body: {"Request", "application/json", DispatchWeb.Schemas.MobileRegisterRequest},
    responses: [
      created: {"Response", "application/json", DispatchWeb.Schemas.MobileDeviceResponse},
      unauthorized: {"Unauthenticated", "application/problem+json", DispatchWeb.Schemas.Problem},
      forbidden: {"Rejected", "application/problem+json", DispatchWeb.Schemas.Problem}
    ]
  )

  alias CoopSubstrate.Enrolments
  alias Dispatch.MobileDevices
  alias DispatchWeb.Problem

  plug :require_ledger

  defp require_ledger(conn, _) do
    if Dispatch.MobileDevices.available?(),
      do: conn,
      else:
        conn
        |> DispatchWeb.Problem.send(
          503,
          "DEVICE_UNAVAILABLE",
          "Device enrolment is temporarily unavailable."
        )
        |> Plug.Conn.halt()
  end


  @spec request(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def request(conn, params) do
    with %{principal: principal, identity: identity} <- conn.assigns[:bizkit_session],
         {:ok, scope} <- MobileDevices.scope(conn.assigns.actor),
         {:ok, public} <- MobileDevices.decode(params["public_key"], 32),
         {:ok, challenge} <-
           Enrolments.begin(principal, identity, scope, params["key_id"], public, params["label"]) do
      conn
      |> put_status(201)
      |> json(%{
        id: challenge.id,
        statement: Base.url_encode64(challenge.statement, padding: false)
      })
    else
      _ -> rejected(conn)
    end
  end

  @spec prove(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def prove(conn, params) do
    with %{principal: principal} <- conn.assigns[:bizkit_session],
         {:ok, signature} <- MobileDevices.decode(params["signature"], 64),
         {:ok, request} <- Enrolments.prove(principal, params["id"], signature) do
      conn |> put_status(201) |> json(request)
    else
      _ -> rejected(conn)
    end
  end

  @spec register(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def register(conn, params) do
    with %{} = session <- conn.assigns[:bizkit_session],
         {:ok, device} <- MobileDevices.register(conn.assigns.actor, session, params) do
      conn |> put_status(201) |> json(%{device_id: device.id})
    else
      _ -> rejected(conn)
    end
  end

  defp rejected(conn),
    do:
      Problem.send(
        conn,
        403,
        "DEVICE_REJECTED",
        "Device access requires an active approved key. Request enrolment or contact your administrator."
      )
end
