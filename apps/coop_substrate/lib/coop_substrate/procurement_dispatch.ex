defmodule CoopSubstrate.ProcurementDispatch do
  @moduledoc """
  Fulfillment for an existing Procurement request. Dispatch owns the handoff
  and its receipts; Procurement applies fulfillment to the original order.
  """
  alias CoopSubstrate.Protocol.Envelope
  alias RestaurantCore.Delivery

  @route "ProcurementDispatchRouteV1"
  @request "ProcurementDispatchRequestedV1"
  @step "ProcurementDispatchStepV1"

  def init, do: %{routes: %{}, transport: Delivery.init()}

  def event_types(operator_fields) do
    %{
      @route =>
        spec("governance", %{
          "cooperative_id" => :string,
          "tenant_id" => :string,
          "site" => :string,
          "key_id" => :string,
          "pubkey" => :pubkey,
          "active" => :bool,
          "expected_version" => :int
        }),
      @request =>
        spec(
          "procurement_operator",
          Map.merge(operator_fields, %{
            "request_id" => :string,
            "expected_version" => :int,
            "pickup_digest" => :string,
            "dropoff_digest" => :string
          })
        ),
      @step =>
        spec(
          "procurement_dispatch",
          %{
            "cooperative_id" => :string,
            "order_id" => :string,
            "tenant_id" => :string,
            "load_id" => :string,
            "assignment_id" => :string,
            "command_id" => :string,
            "expected_version" => :int,
            "op" => :string,
            "automated" => :bool
          },
          %{"proof_id" => :string, "proof_digest" => :string}
        )
    }
  end

  defp spec(role, fields, optional \\ %{}) do
    %{
      required_roles: [role],
      disclosure_class: :own_data,
      stream: {:payload_field, "private-procurement", "cooperative_id"},
      payload: %{required: fields, optional: optional}
    }
  end

  def route(state, chapter, coop), do: state.dispatch.routes[{chapter, coop}]

  def key(state, chapter, coop, tenant, key_id) do
    case route(state, chapter, coop) do
      %{active: true, tenant: ^tenant, key_id: ^key_id, pubkey: pubkey} -> {:ok, pubkey}
      _ -> {:error, :procurement_dispatch_forbidden}
    end
  end

  def configure(state, %Envelope{chapter_id: chapter, payload: p}) do
    scope = {chapter, p["cooperative_id"]}
    previous = state.dispatch.routes[scope]
    version = if previous, do: previous.version, else: 0

    with true <- p["expected_version"] == version or {:error, :stale_dispatch_route},
         true <- Delivery.uuid?(p["tenant_id"]) and valid_site?(p["site"]),
         :ok <- route_change(state, scope, previous, p),
         {:bytes, <<_::256>> = pubkey} <- p["pubkey"] do
      route = %{
        tenant: p["tenant_id"],
        site: p["site"],
        key_id: p["key_id"],
        pubkey: pubkey,
        active: p["active"],
        version: version + 1
      }

      {:ok, put_in(state, [:dispatch, :routes, Access.key(scope)], route)}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_dispatch_route}
    end
  end

  defp route_change(_state, _scope, nil, _payload), do: :ok

  defp route_change(state, {chapter, coop}, previous, payload) do
    changed = {previous.tenant, previous.site} != {payload["tenant_id"], payload["site"]}

    if changed and
         Enum.any?(state.requests, fn
           {{^chapter, ^coop, _}, %{phase: :accepted, dispatch: _}} -> true
           _ -> false
         end) do
      {:error, :procurement_dispatch_route_in_use}
    else
      :ok
    end
  end

  def request(state, %Envelope{chapter_id: chapter, payload: p}) do
    coop = p["cooperative_id"]
    id = p["request_id"]
    scope = {chapter, coop, id}

    with %{phase: :accepted, accepted_quote: quote, version: version} = row <-
           state.requests[scope],
         false <- Map.has_key?(row, :dispatch),
         true <- version == p["expected_version"] or {:error, :stale_version},
         %{active: true} = route <- route(state, chapter, coop),
         true <-
           (enrolled?(state, chapter, coop, row.request.buyer_business_id) and
              enrolled?(state, chapter, coop, quote.merchant_business_id)) or
             {:error, :business_not_enrolled},
         {:ok, order} <-
           Delivery.bind_checkout(%{fulfillment: :delivery, id: id}, %{
             "profile" => "automatic-v1",
             "site" => route.site,
             "request_id" => id,
             "pickup_digest" => p["pickup_digest"],
             "dropoff_digest" => p["dropoff_digest"]
           }) do
      dispatch =
        Map.merge(order.automated_delivery, %{tenant: route.tenant, accepted_version: version})

      row = row |> Map.put(:dispatch, dispatch) |> Map.put(:version, version + 1)
      {:ok, put_in(state, [:requests, Access.key(scope)], row)}
    else
      true -> {:error, :dispatch_already_requested}
      {:error, _} = error -> error
      _ -> {:error, :procurement_order_not_dispatchable}
    end
  end

  # Once the handoff is accepted, a cancellation or external fulfillment
  # would race custody. Before acceptance, cancellation fences that handoff.
  def permit_commercial(state, {chapter, coop, id} = scope, action) do
    case {state.requests[scope], action} do
      {%{phase: :accepted, dispatch: _}, action} when action in [:fulfill, :dispute] ->
        {:error, :dispatch_handoff_in_progress}

      {%{phase: :accepted, dispatch: _}, :cancel} ->
        if Delivery.handoff(state.dispatch.transport, chapter, coop, id),
          do: {:error, :dispatch_custody_reconciliation_required},
          else: :ok

      _ ->
        :ok
    end
  end

  def step(state, %Envelope{chapter_id: chapter, payload: p, signers: [signer]} = env, fulfill) do
    coop = p["cooperative_id"]
    id = p["order_id"]
    scope = {chapter, coop, id}
    tenant = p["tenant_id"]

    with {:ok, pubkey} <- key(state, chapter, coop, tenant, signer.key_id),
         true <- signer.role == "procurement_dispatch" and pubkey == signer.pubkey,
         %{dispatch: %{tenant: ^tenant, site: site}} = row <- state.requests[scope],
         %{site: ^site} <- route(state, chapter, coop),
         {:ok, order} <- order_view(row, state.dispatch.transport, chapter, coop, id),
         {:ok, transport, mirror} <-
           Delivery.apply(state.dispatch.transport, chapter, coop, order, p),
         {:ok, row} <- finish(row, mirror, env, fulfill) do
      {:ok,
       state
       |> put_in([:dispatch, :transport], transport)
       |> put_in([:requests, Access.key(scope)], row)}
    else
      {:error, _} = error -> error
      _ -> {:error, :procurement_dispatch_forbidden}
    end
  end

  defp order_view(%{phase: phase, dispatch: codes}, transport, chapter, coop, id)
       when phase in [:accepted, :fulfilled, :disputed] do
    stage =
      case Delivery.handoff(transport, chapter, coop, id) do
        %{phase: :delivered} -> :completed
        %{phase: :in_transit} -> :dispatched
        _ -> :ready
      end

    # This is a reducer input over the existing request ID. Only the transport
    # fold and the original procurement row are persisted.
    {:ok,
     %{
       id: id,
       merchant: coop,
       fulfillment: :delivery,
       state: stage,
       version: 0,
       automated_delivery: codes
     }}
  end

  defp order_view(_, _, _, _, _), do: {:error, :delivery_order_not_ready}

  defp finish(row, %{state: :completed}, env, fulfill), do: fulfill.(row, env)
  defp finish(row, _, _, _), do: {:ok, row}

  def work(state, chapter, coop, tenant, cursor) do
    state.requests
    |> Enum.filter(fn {{ch, c, id}, _} -> ch == chapter and c == coop and id > cursor end)
    |> Enum.sort_by(fn {{_, _, id}, _} -> id end)
    |> Stream.flat_map(fn
      {{_, _, id}, %{dispatch: %{tenant: ^tenant, site: site}} = row} ->
        case {row.phase, Delivery.handoff(state.dispatch.transport, chapter, coop, id)} do
          {:accepted, nil} ->
            [%{order_id: id, site: site, phase: "requested"}]

          {:cancelled, nil} ->
            [%{order_id: id, site: site, phase: "cancelled"}]

          {_, %{phase: phase} = handoff} when phase in [:accepted, :delivered] ->
            [
              %{
                order_id: id,
                site: site,
                phase: Atom.to_string(phase),
                load_id: handoff.transport_ref,
                assignment_id: handoff.dispatch_assignment
              }
            ]

          _ ->
            []
        end

      _ ->
        []
    end)
    |> Enum.take(25)
  end

  def handoff_phase(state, {chapter, coop, id}) do
    case Delivery.handoff(state.dispatch.transport, chapter, coop, id) do
      %{phase: phase} -> phase
      nil -> :requested
    end
  end

  defp enrolled?(state, chapter, coop, business),
    do: match?(%{active: true}, state.businesses[{chapter, coop, business}])

  defp valid_site?(site),
    do: is_binary(site) and byte_size(site) in 1..120 and String.trim(site) != ""
end
