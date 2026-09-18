defmodule DispatchWeb.PortalController do
  @moduledoc """
  The role-scoped portal pages of Section 4.3.

  Section 21.1 confines a controller to transport, and that holds here in an
  unusually literal way: every page is a view model plus a component, and the
  controller's whole job is to turn `{:error, :not_found}` into a 404 without
  saying anything more than that.

  Section 4.3 gives each profile a primary route. The routes are separate
  because the surfaces are, not because the code is: a shipper and a dispatcher
  look at different objects with different fields, and one page with role
  branching inside it would be exactly the "hard-coded user type" Section 23.2's
  capability model exists to avoid.
  """

  use Phoenix.Controller, formats: [:html]

  import Plug.Conn

  alias Dispatch.Identity.PrincipalResolution
  alias DispatchWeb.ViewModels.{OperationsParticipantView, OperationsView, PartnerStopView}

  @doc "The carrier-scoped operations overview (Section 4.4)."
  @spec operations(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def operations(conn, _params) do
    case OperationsView.build(conn.assigns.actor) do
      {:ok, view} -> page(conn, :operations, view)
      {:error, :not_found} -> not_found(conn)
    end
  end

  @doc "A shipper's or receiver's stop page (Section 4.3)."
  @spec partner_stop(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def partner_stop(conn, %{"stop_id" => stop_id}) do
    case PartnerStopView.build(conn.assigns.actor, stop_id) do
      {:ok, view} -> page(conn, :partner_stop, view)
      {:error, :not_found} -> not_found(conn)
    end
  end

  @doc "An operations participant page (Section 4.3)."
  @spec operations_participant(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def operations_participant(conn, %{"participant_id" => participant_id}) do
    case OperationsParticipantView.build(conn.assigns.actor, participant_id) do
      {:ok, view} -> page(conn, :operations_participant, view)
      {:error, :not_found} -> not_found(conn)
    end
  end

  @doc """
  The `DRIVER` compatibility projection of `operations_participant/2`.

  Section 4.3 and Section 24.3 both keep a role-filtered projection beside the
  canonical route. Same function body, so the two cannot drift.
  """
  @spec operations_driver(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def operations_driver(conn, %{"driver_id" => driver_id}) do
    operations_participant(conn, %{"participant_id" => driver_id})
  end

  defp page(conn, template, view) do
    render(conn, template,
      view: view,
      actor: conn.assigns.actor,
      assignments: switchable_assignments(conn)
    )
  end

  # One response for "no such row", "not yours", and "not in your tenant".
  # Acceptance criterion 19 requires an unrelated subject to bear no
  # existence-bearing metadata, and a 403 here would be exactly that metadata.
  defp not_found(conn) do
    conn
    |> put_status(:not_found)
    |> render(:not_found)
  end

  # What the switcher may offer: the assignments this principal actually holds,
  # re-read rather than remembered. Section 24.6's selection is among these and
  # nothing else.
  defp switchable_assignments(conn) do
    case get_session(conn, DispatchWeb.Plugs.PortalSession.subject_key()) do
      subject when is_binary(subject) -> PrincipalResolution.selectable(subject)
      _none -> []
    end
  end
end
