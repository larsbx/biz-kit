defmodule DispatchWeb.OperationsLoadControllerTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias Dispatch.Support.{Fixtures, PortalIdentity}
  alias DispatchWeb.Plugs.PortalSession

  @moduletag :integration
  @session Plug.Session.init(
             store: :cookie,
             key: "_dispatch_session",
             signing_salt: "5xJq0pQe",
             encryption_salt: "Nn4vT2kA"
           )

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Dispatch.Repo)
    :ok = PortalIdentity.setup()
    carrier = Fixtures.carrier()
    %{user: user, participant: desk} = Fixtures.person(carrier.id, carrier)
    dispatcher = Fixtures.actor(carrier.id, carrier, desk, "DISPATCHER")

    load =
      Fixtures.load(carrier.id, carrier,
        commodity_text: "<script>throw new Error('unsafe')</script>",
        currency: "USD",
        agreed_rate_minor: 999_888_777
      )

    stop =
      Fixtures.stop(carrier.id, load, :PICKUP,
        address_text: "42 Collection Road",
        contact_phone_e164: "+15551234567"
      )

    %{carrier: carrier, user: user, desk: desk, dispatcher: dispatcher, load: load, stop: stop}
  end

  defp page(ctx, load_id, actor \\ nil) do
    actor = actor || ctx.dispatcher

    entries =
      PortalIdentity.bind([
        {PortalSession.subject_key(), ctx.user.oidc_subject},
        {PortalSession.assignment_key(), actor.role_assignment.id}
      ])

    conn(:get, "/operations/loads/#{load_id}")
    |> Map.put(
      :secret_key_base,
      Application.fetch_env!(:dispatch, DispatchWeb.Endpoint)[:secret_key_base]
    )
    |> Plug.Session.call(@session)
    |> fetch_session()
    |> then(&Enum.reduce(entries, &1, fn {key, value}, conn -> put_session(conn, key, value) end))
    |> DispatchWeb.Router.call(DispatchWeb.Router.init([]))
  end

  test "ordinary dispatcher authority opens a read-only load with planned stops", ctx do
    response = page(ctx, ctx.load.id)
    assert response.status == 200
    assert get_resp_header(response, "cache-control") == ["no-store"]
    assert get_resp_header(response, "referrer-policy") == ["no-referrer"]
    assert response.resp_body =~ "id=\"operations-load\""
    assert response.resp_body =~ "id=\"stop-#{ctx.stop.id}\""
    assert response.resp_body =~ ctx.load.external_reference
    assert response.resp_body =~ "42 Collection Road"
    assert response.resp_body =~ "Next stop is unknown"
    assert response.resp_body =~ "&lt;script&gt;"
    refute response.resp_body =~ "<script>throw"
    refute response.resp_body =~ "+15551234567"
    refute response.resp_body =~ "999888777"
    refute response.resp_body =~ "data-on:"
    refute response.resp_body =~ "/transitions"
  end

  test "foreign and missing loads have the same empty refusal", ctx do
    other = Fixtures.organization(ctx.carrier.id, :CARRIER)
    foreign = Fixtures.load(ctx.carrier.id, other)
    elsewhere = Fixtures.carrier()
    outside = Fixtures.load(elsewhere.id, elsewhere)

    for id <- [foreign.id, outside.id, Ecto.UUID.generate(), "not-a-uuid"] do
      response = page(ctx, id)
      assert response.status == 404
      assert response.resp_body == ""
    end
  end

  test "load read alone does not disclose assignment or stop context", ctx do
    definition =
      Dispatch.Accounts.RoleDefinition
      |> Ash.Changeset.for_create(:seed, %{
        tenant_id: ctx.carrier.id,
        key: "LOAD_ONLY",
        label: "Load only",
        capabilities_json: ["load.read"],
        profile_module: ctx.dispatcher.role_assignment.role_definition.profile_module
      })
      |> Ash.create!(authorize?: false, tenant: ctx.carrier.id)

    actor =
      Fixtures.actor(ctx.carrier.id, ctx.carrier, ctx.desk, definition.key,
        definition: definition,
        scope_type: :ORGANIZATION
      )

    response = page(ctx, ctx.load.id, actor)
    assert response.status == 404
    assert response.resp_body == ""
  end

  test "a stale actor cannot reopen its record after role revocation", ctx do
    assert {:ok, _, _} = Dispatch.Operations.LocationWork.load(ctx.dispatcher, ctx.load.id)
    Fixtures.revoke(ctx.carrier.id, ctx.dispatcher.role_assignment)

    assert Dispatch.Operations.LocationWork.load(ctx.dispatcher, ctx.load.id) ==
             {:error, :not_found}

    refute page(ctx, ctx.load.id).status == 200
  end
end
