defmodule DispatchWeb.SettingsController do
  @moduledoc """
  `/settings/users`: an administrator's role management (Sections 4.3, 23.3).

  Transport only (Section 21.1). `Dispatch.Accounts.Administration` decides;
  this turns its refusals into statuses and a sentence, and runs each change
  under the form's idempotency key, so a resubmitted form is answered once.
  """

  use Phoenix.Controller, formats: [:html]

  import Plug.Conn

  alias Dispatch.Accounts.Administration
  alias Dispatch.Idempotency
  alias DispatchWeb.Plugs.PortalSession

  @users "/settings/users"

  @doc "ADMIN's primary route (Section 4.3)."
  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, _params), do: see_other(conn, @users)

  @doc "The organization's people and their role assignments."
  @spec users(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def users(conn, _params), do: page(conn, :ok, nil)

  @doc "Grants a role to someone in the organization."
  @spec grant(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def grant(conn, params) do
    change(conn, params, fn actor ->
      Administration.grant(actor, params, PortalSession.authenticated_at(conn))
    end)
  end

  @doc "Revokes an assignment, at the version the page showed."
  @spec revoke(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def revoke(conn, %{"assignment_id" => id} = params) do
    change(conn, params, fn actor ->
      Administration.revoke(
        actor,
        id,
        version(params["expected_version"]),
        PortalSession.authenticated_at(conn)
      )
    end)
  end

  # Section 23.3 requires a key on every administrative change; a form that
  # lost its key is refused rather than run without one.
  defp change(conn, %{"idempotency_key" => key} = params, fun)
       when is_binary(key) and key != "" do
    actor = conn.assigns.actor
    body = Map.drop(params, ["_csrf_token", "idempotency_key"])

    actor
    |> Idempotency.execute(key, body, fn ->
      case fun.(actor) do
        {:ok, _changed} -> {:ok, 303, %{"location" => @users}}
        {:error, reason} -> {:error, reason}
      end
    end)
    |> case do
      {:ok, 303, %{"location" => location}} -> see_other(conn, location)
      {:error, reason} -> refused(conn, reason)
    end
  end

  defp change(conn, _keyless, _fun), do: refused(conn, :idempotency_key_required)

  defp refused(conn, :not_found), do: not_found(conn)
  defp refused(conn, reason), do: page(conn, status(reason), message(reason))

  defp status(:step_up_required), do: :forbidden
  defp status(:own_assignment), do: :forbidden
  defp status(:idempotency_key_required), do: :bad_request
  defp status(_conflict), do: :conflict

  defp message(:step_up_required),
    do:
      "Changing roles needs a recent sign-in. Sign in again, then repeat the change " <>
        "within #{div(Administration.step_up_seconds(), 60)} minutes."

  defp message(:own_assignment),
    do: "No one can grant themselves a role. Ask another administrator."

  defp message(:last_administrator),
    do: "The organization's last administrator cannot be removed."

  defp message(:already_granted), do: "That person already holds that role."

  defp message(:stale),
    do: "That assignment changed since this page was shown. Review it and try again."

  defp message(:key_reused),
    do: "This form was already used for a different change. Reload the page."

  defp message(:in_progress), do: "This change is still being made. Reload the page shortly."
  defp message(:idempotency_key_required), do: "The form was incomplete. Reload the page."
  defp message(_other), do: "The change was not made."

  defp version(value) when is_binary(value) do
    case Integer.parse(value) do
      {version, ""} -> version
      _not_a_version -> -1
    end
  end

  # Absent is not a wildcard: Administration refuses it as stale.
  defp version(_absent), do: nil

  defp page(conn, status, message) do
    case Administration.overview(conn.assigns.actor) do
      {:ok, view} ->
        conn
        |> put_status(status)
        |> render(:users,
          view: view,
          actor: conn.assigns.actor,
          message: message,
          step_up_seconds: Administration.step_up_seconds()
        )

      {:error, :not_found} ->
        not_found(conn)
    end
  end

  defp not_found(conn) do
    conn
    |> put_status(:not_found)
    |> put_view(DispatchWeb.PortalHTML)
    |> render(:not_found)
  end

  defp see_other(conn, location) do
    conn
    |> put_resp_header("location", location)
    |> send_resp(:see_other, "")
  end
end
