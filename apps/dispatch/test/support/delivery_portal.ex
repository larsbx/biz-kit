defmodule Dispatch.Support.DeliveryPortal do
  @moduledoc false

  import ExUnit.Assertions
  import Plug.Conn
  import Plug.Test

  alias Dispatch.Accounts.RoleAssignment
  alias Dispatch.Support.PortalIdentity

  @portal_path "/ui/restaurant-receipts"
  @session Plug.Session.init(
             store: :cookie,
             key: "_dispatch_session",
             signing_salt: "5xJq0pQe",
             encryption_salt: "Nn4vT2kA"
           )

  def service_role(tenant) do
    definition = Fixtures.role_definition(tenant, "DISPATCHER")

    RoleAssignment
    |> Ash.Changeset.for_create(:grant, %{
      tenant_id: tenant,
      principal_type: :SERVICE,
      principal_id: Ash.UUID.generate(),
      organization_id: tenant,
      role_definition_id: definition.id,
      scope_type: :ORGANIZATION,
      starts_at: DateTime.add(DateTime.utc_now(), -60)
    })
    |> Ash.create!(authorize?: false, tenant: tenant)
    |> Ash.load!([:role_definition], authorize?: false, tenant: tenant)
  end

  defp portal(method, path, params \\ %{}, previous \\ nil) do
    Plug.CSRFProtection.delete_csrf_token()
    request = conn(method, path, params)

    request = %{
      request
      | secret_key_base: Application.fetch_env!(:dispatch, DispatchWeb.Endpoint)[:secret_key_base]
    }

    request = if previous, do: recycle_cookies(request, previous), else: request

    request
    |> Plug.RequestId.call(Plug.RequestId.init(assign_as: :correlation_id))
    |> Plug.Session.call(@session)
    |> fetch_session()
    |> DispatchWeb.Router.call(DispatchWeb.Router.init([]))
  end

  defp csrf(page),
    do: Regex.run(~r/name="_csrf_token" value="([^"]+)"/, page.resp_body) |> Enum.at(1)

  def login(user, role) do
    form = portal(:get, "/login")

    signed_in =
      portal(
        :post,
        "/session",
        %{"_csrf_token" => csrf(form), "token" => PortalIdentity.token_for(user.oidc_subject)},
        form
      )

    assert signed_in.status == 302
    choose = portal(:get, "/select-role", %{}, signed_in)
    assert choose.status == 200

    selected =
      portal(
        :post,
        "/select-role",
        %{"_csrf_token" => csrf(choose), "role_assignment_id" => role.id},
        choose
      )

    assert selected.status == 302
    page = portal(:get, @portal_path, %{}, selected)
    assert page.status == 200
    page
  end

  def receipt(page, trip, phase, code) do
    portal(
      :post,
      @portal_path,
      %{
        "_csrf_token" => csrf(page),
        "assignment_id" => trip.id,
        "phase" => phase,
        "handoff_token" => code
      },
      page
    )
  end
end
