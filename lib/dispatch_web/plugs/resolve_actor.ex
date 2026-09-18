defmodule DispatchWeb.Plugs.ResolveActor do
  @moduledoc """
  Selects the one role assignment a request acts under (Sections 23.3, 24.6).

  Section 24.6: "Authenticated machine requests send `X-Role-Assignment-ID`; the
  server verifies ownership, tenant, validity interval, scope, capability, and
  related load/stop party row. The header or session value selects authority
  context but never grants it."

  Section 21.1 confines this layer to transport, so the plug does exactly two
  things: read the header, and map the outcome to a status. Every verification
  in that sentence happens in `Dispatch.Identity.PrincipalResolution`, where it
  is reachable from the portal session path and from tests without a connection.
  """

  @behaviour Plug

  import Plug.Conn

  alias Dispatch.Identity.PrincipalResolution

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%{assigns: %{oidc_claims: %{subject: subject}}} = conn, _opts) do
    subject
    |> PrincipalResolution.actor(requested_assignment(conn))
    |> case do
      {:ok, actor} ->
        conn
        |> assign(:actor, actor)
        |> assign(:tenant, actor.tenant_id)

      {:error, reason} ->
        {code, detail} = problem_for(reason)
        DispatchWeb.Problem.send(conn, 403, code, detail)
    end
  end

  def call(conn, _opts) do
    DispatchWeb.Problem.send(conn, 401, "UNAUTHENTICATED", "A valid bearer token is required.")
  end

  defp requested_assignment(conn) do
    case get_req_header(conn, "x-role-assignment-id") do
      [value | _rest] -> value
      [] -> nil
    end
  end

  # Ambiguity is the one case the client can act on, so it says what to send.
  # The rest collapse to a single code: a caller learns that this request is not
  # authorized, not whether the assignment they named exists for someone else.
  defp problem_for(:no_active_assignment),
    do: {"NO_ACTIVE_ROLE_ASSIGNMENT", "No active role assignment for this principal."}

  defp problem_for(:ambiguous_role_assignment),
    do:
      {"ROLE_ASSIGNMENT_REQUIRED",
       "Several active role assignments exist; send X-Role-Assignment-ID to select one."}

  defp problem_for(_other),
    do: {"ROLE_ASSIGNMENT_INVALID", "The selected role assignment is not usable."}
end
