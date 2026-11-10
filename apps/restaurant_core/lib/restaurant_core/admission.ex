defmodule RestaurantCore.Admission do
  @moduledoc """
  Which signed restaurant events exist and whether one may be appended. Pure,
  in the shape of `TaskCore.Admission`: the substrate registers the types, runs
  `check/2` inside its single appender and folds admitted events with `fold/2`,
  so concurrent submissions are judged one at a time against the advancing
  state (eight copies of one checkout place one order).

    * `RestaurantDeviceGrantedV1`, signed by a declared governance key, binds a
      device key to a merchant, an actor class and its allowed actions.
    * `RestaurantOrderPlacedV1`, signed by a device granted `checkout`, runs
      `OrderCore.Placement` over the kitchen workflow and starts the order. The
      device prices the order (`CommerceCore.Checkout`) before signing; the
      snapshot is recorded in integer minor units and checked for shape only.
    * `RestaurantOrderStepV1`, signed by a granted device, runs
      `RestaurantCore.Kitchen.apply/3`.

  The trusted context is derived from the grant, never from the payload, and
  the outcome is exactly the reducers' outcome (`admit/3` serves both check and
  fold). Every event is a business fact: none asserts payment or settlement.
  Money is Hawala's: nothing here computes, accepts or settles an amount.
  """

  alias OrderCore.Placement
  alias RestaurantCore.{Delivery, Kitchen, Menu}

  @grant "RestaurantDeviceGrantedV1"
  @revoke "RestaurantDeviceRevokedV1"
  @menu "RestaurantMenuPublishedV1"
  @placed "RestaurantOrderPlacedV1"
  @step "RestaurantOrderStepV1"
  @device "restaurant_device"
  @dispatch "restaurant_dispatch"
  @dispatch_grant "RestaurantDispatchGrantedV1"
  @delivery_step "RestaurantDeliveryStepV1"

  @actors Map.new(~w(admin staff system)a, &{Atom.to_string(&1), &1})
  @actions Map.new([:checkout | Map.keys(Kitchen.workflow().actions)], &{Atom.to_string(&1), &1})
  @channels Map.new(Placement.channels(), &{Atom.to_string(&1), &1})
  @fulfillments Map.new(Kitchen.workflow().fulfillments, &{Atom.to_string(&1), &1})
  @adjustments Map.new(~w(discount_total tax_total delivery_fee tip)a, &{Atom.to_string(&1), &1})

  def event_types do
    %{
      @dispatch_grant =>
        spec("governance", "restaurant_devices", ["merchant_id"], %{
          "merchant_id" => :string,
          "tenant_id" => :string,
          "key_id" => :string,
          "pubkey" => :pubkey
        }),
      @delivery_step =>
        spec(
          @dispatch,
          "restaurant_orders",
          ["merchant_id", "order_id"],
          %{
            "merchant_id" => :string,
            "order_id" => :string,
            "tenant_id" => :string,
            "load_id" => :string,
            "assignment_id" => :string,
            "command_id" => :string,
            "expected_version" => :int,
            "op" => :string
          },
          %{"proof_id" => :string, "proof_digest" => :string, "automated" => :bool}
        ),
      @grant =>
        spec("governance", "restaurant_devices", ["merchant_id"], %{
          "merchant_id" => :string,
          "device_id" => :string,
          "key_id" => :string,
          "pubkey" => :pubkey,
          "actor" => :string,
          "actions" => :any
        }),
      @revoke =>
        spec("governance", "restaurant_devices", ["merchant_id"], %{
          "merchant_id" => :string,
          "key_id" => :string
        }),
      @menu =>
        spec("governance", "restaurant_menu", ["merchant_id"], %{
          "merchant_id" => :string,
          "expected_revision" => :int,
          "currency" => :string,
          "items" => :any
        }),
      @placed =>
        spec(
          @device,
          "restaurant_orders",
          ["merchant_id", "order_id"],
          %{
            "merchant_id" => :string,
            "order_id" => :string,
            "cart_id" => :string,
            "principal_id" => :string,
            "channel" => :string,
            "idempotency_key" => :string,
            "fulfillment" => :string,
            "currency" => :string,
            "lines" => :any,
            "adjustments" => :any,
            "subtotal_minor" => :int,
            "total_minor" => :int
          },
          %{"delivery" => :any, "pickup_name" => :string, "menu_revision" => :int}
        ),
      @step =>
        spec(
          @device,
          "restaurant_orders",
          ["merchant_id", "order_id"],
          %{
            "merchant_id" => :string,
            "order_id" => :string,
            "command_id" => :string,
            "expected_version" => :int,
            "action" => :string
          },
          %{"reason" => :string, "staff_principal" => :string}
        )
    }
  end

  defp spec(role, prefix, stream, required, optional \\ %{}),
    do: %{
      required_roles: [role],
      disclosure_class: :edges,
      stream: {:payload_fields, prefix, stream},
      payload: %{required: required, optional: optional}
    }

  def init, do: %{grants: %{}, merchants: %{}, menus: %{}, delivery: Delivery.init()}

  def menu(state, chapter, merchant),
    do: get_in(state, [:menus, {chapter, merchant}])

  def active_device?(state, chapter, merchant, signer) do
    case state.grants[{chapter, merchant, signer.key_id}] do
      %{actor: actor, pubkey: pubkey} = grant when actor != :dispatch ->
        pubkey == signer.pubkey and not Map.get(grant, :revoked, false)

      _ ->
        false
    end
  end

  def dispatch_available?(state, chapter, merchant) do
    Enum.any?(state.grants, fn
      {{^chapter, ^merchant, _}, %{actor: :dispatch} = grant} ->
        not Map.get(grant, :revoked, false)

      _ ->
        false
    end)
  end

  def dispatch_key(state, chapter, merchant, tenant, key_id) do
    case state.grants[{chapter, merchant, key_id}] do
      %{actor: :dispatch, tenant: ^tenant, pubkey: pubkey} = grant ->
        if Map.get(grant, :revoked, false), do: :error, else: {:ok, pubkey}

      _ ->
        :error
    end
  end

  @doc "Opaque automation work from the same replayable order and handoff projection."
  def delivery_work(state, chapter, merchant, tenant, after_id) do
    orders = get_in(state, [:merchants, {chapter, merchant}, :orders]) || %{}

    orders
    |> Enum.filter(fn {id, order} ->
      id > after_id and Map.has_key?(order, :automated_delivery)
    end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Stream.flat_map(fn {id, order} ->
      site = order.automated_delivery.site
      handoff = Delivery.handoff(state.delivery, chapter, merchant, id)

      case {order.state, handoff} do
        {stage, nil} when stage in [:ready, :cancelled] ->
          phase = if stage == :ready, do: "requested", else: "cancelled"
          [%{order_id: id, site: site, phase: phase}]

        {_, %{dispatch_tenant: ^tenant, phase: phase} = h}
        when phase in [:accepted, :delivered] ->
          [
            %{
              order_id: id,
              site: site,
              phase: Atom.to_string(phase),
              load_id: h.transport_ref,
              assignment_id: h.dispatch_assignment
            }
          ]

        _ ->
          []
      end
    end)
    |> Enum.take(25)
  end

  @doc "`:ok` when the event may be appended to a gate holding `role_keys` and `restaurant`."
  def check(env, gate) do
    with {:ok, _} <- admit(env, gate.role_keys, gate.restaurant), do: :ok
  end

  @doc "The restaurant state after an admitted event."
  def fold(env, gate) do
    {:ok, state} = admit(env, gate.role_keys, gate.restaurant)
    state
  end

  @doc "An order's lifecycle state, or nil."
  def state(state, chapter, merchant, order_id),
    do: get_in(state, [:merchants, {chapter, merchant}, :orders, order_id])

  @doc """
  A merchant's orders, oldest first by id: each order's lifecycle (`state`,
  `version`, the `actions` it can take now) joined with its signed snapshot.
  """
  def orders(state, chapter, merchant) do
    case get_in(state, [:merchants, {chapter, merchant}]) do
      nil ->
        []

      %{checkout: %{orders: placed}, orders: orders, index: index, details: details} ->
        index
        |> Enum.map(fn {key, id} ->
          order = Map.fetch!(orders, id)
          handoff = Delivery.handoff(state.delivery, chapter, merchant, id)

          placed
          |> Map.fetch!(key)
          |> Map.take([
            :principal,
            :channel,
            :fulfillment,
            :currency,
            :lines,
            :subtotal,
            :total,
            :adjustments
          ])
          |> Map.merge(%{
            id: id,
            state: order.state,
            version: order.version,
            actions: order_actions(order, handoff),
            delivery: public_handoff(order, handoff),
            delivery_site: get_in(order, [:automated_delivery, :site])
          })
          |> Map.merge(Map.fetch!(details, id))
        end)
        |> Enum.sort_by(& &1.id)
    end
  end

  defp order_actions(order, nil), do: Kitchen.available_actions(order)
  defp order_actions(order, _handoff), do: Kitchen.available_actions(order) -- [:cancel]

  defp public_handoff(%{fulfillment: :delivery, state: :ready}, nil),
    do: %{phase: :requested, version: 0}

  defp public_handoff(_, nil), do: nil
  defp public_handoff(_, handoff), do: Map.take(handoff, [:phase, :version])

  @spec admit(map(), map(), map()) :: {:ok, map()} | {:error, term()}
  def admit(%{signers: [_]} = env, keys, state), do: admit_one(env, keys, state)
  def admit(_, _, _), do: {:error, :restaurant_signer_cardinality}

  defp admit_one(%{type: @grant, chapter_id: ch, signers: [signer], payload: p}, keys, state) do
    id = {ch, p["merchant_id"], p["key_id"]}

    with :ok <- governance(ch, signer, keys),
         {:ok, grant} <- decode_grant(p),
         :ok <-
           if(Map.has_key?(state.grants, id),
             do: {:error, :restaurant_key_already_granted},
             else: :ok
           ) do
      {:ok, put_in(state, [:grants, id], grant)}
    end
  end

  defp admit_one(
         %{type: @dispatch_grant, chapter_id: ch, signers: [signer], payload: p},
         keys,
         state
       ) do
    id = {ch, p["merchant_id"], p["key_id"]}

    with :ok <- governance(ch, signer, keys),
         true <- Delivery.uuid?(p["tenant_id"]) or {:error, :invalid_dispatch_tenant},
         false <- Map.has_key?(state.grants, id),
         {:bytes, <<_::256>> = pubkey} <- p["pubkey"] do
      grant = %{actor: :dispatch, tenant: p["tenant_id"], pubkey: pubkey}
      {:ok, put_in(state, [:grants, id], grant)}
    else
      {:error, _} = error -> error
      true -> {:error, :restaurant_key_already_granted}
      _ -> {:error, :invalid_dispatch_grant}
    end
  end

  defp admit_one(
         %{type: @delivery_step, chapter_id: ch, signers: [signer], payload: p},
         _keys,
         state
       ) do
    merchant = p["merchant_id"]
    order_id = p["order_id"]
    id = {ch, merchant, signer.key_id}

    with %{actor: :dispatch, tenant: tenant, pubkey: pubkey} = grant <- state.grants[id],
         true <- tenant == p["tenant_id"] and pubkey == signer.pubkey,
         false <- Map.get(grant, :revoked, false),
         order = state(state, ch, merchant, order_id),
         {:ok, delivery, order} <- Delivery.apply(state.delivery, ch, merchant, order, p) do
      {:ok,
       state
       |> Map.put(:delivery, delivery)
       |> put_in([:merchants, {ch, merchant}, :orders, order_id], order)}
    else
      {:error, _} = error -> error
      _ -> {:error, :forbidden}
    end
  end

  defp admit_one(%{type: @revoke, chapter_id: ch, signers: [signer], payload: p}, keys, state) do
    id = {ch, p["merchant_id"], p["key_id"]}

    with :ok <- governance(ch, signer, keys),
         %{} = grant <- state.grants[id],
         false <- Map.get(grant, :revoked, false) do
      {:ok, put_in(state, [:grants, id], Map.put(grant, :revoked, true))}
    else
      {:error, _} = error -> error
      _ -> {:error, :restaurant_device_not_active}
    end
  end

  defp admit_one(%{type: @menu, chapter_id: ch, signers: [signer], payload: p}, keys, state) do
    merchant = p["merchant_id"]
    current = menu(state, ch, merchant)
    revision = if current, do: current.revision, else: 0

    with :ok <- governance(ch, signer, keys),
         true <- p["expected_revision"] == revision or {:error, :stale_menu},
         true <- Menu.valid?(p["currency"], p["items"]) or {:error, :invalid_restaurant_menu} do
      publication = %{revision: revision + 1, currency: p["currency"], items: p["items"]}
      {:ok, put_in(state, [:menus, {ch, merchant}], publication)}
    end
  end

  defp admit_one(%{type: @placed, chapter_id: ch, payload: p} = env, _keys, state) do
    with {:ok, _grant} <- device(env, state, :checkout),
         {:ok, cmd, cart, snapshot} <- decode_checkout(p),
         true <- name?(Map.get(p, "pickup_name")) or {:error, :invalid_checkout_command},
         {:ok, merchant} <- merchant(state, ch, p["merchant_id"]),
         :ok <-
           if(Map.has_key?(merchant.orders, p["order_id"]),
             do: {:error, :order_exists},
             else: :ok
           ),
         projection = %{
           merchant.checkout
           | carts: Map.put_new(merchant.checkout.carts, cmd.cart_id, cart)
         },
         trusted = %{
           granted: true,
           operation: :checkout,
           principal: p["principal_id"],
           merchant: p["merchant_id"],
           cart_id: cmd.cart_id
         },
         {:ok, checkout} <-
           placed(
             Placement.apply(projection, trusted, cmd, fn cart, command ->
               with :ok <- checkout_menu(menu(state, ch, p["merchant_id"]), p),
                    do: snapshot.(cart, command)
             end),
             merchant,
             cmd
           ),
         {:ok, order} <- Kitchen.new(p["merchant_id"], p["order_id"], cmd.fulfillment),
         {:ok, order} <- Delivery.bind_checkout(order, p["delivery"]) do
      {:ok,
       put_in(state, [:merchants, {ch, p["merchant_id"]}], %{
         checkout: checkout,
         orders: Map.put(merchant.orders, p["order_id"], order),
         details:
           Map.put(merchant.details, p["order_id"], %{
             pickup_name: p["pickup_name"],
             menu_revision: Map.get(p, "menu_revision", 0)
           }),
         index: Map.put(merchant.index, {cmd.channel, cmd.idempotency_key}, p["order_id"])
       })}
    end
  end

  defp admit_one(%{type: @step, chapter_id: ch, payload: p} = env, _keys, state) do
    with {:ok, grant} <- device(env, state, nil),
         :ok <- cancellation_allowed(state.delivery, ch, p) do
      trusted = %{
        merchant: p["merchant_id"],
        order_id: p["order_id"],
        principal: grant.device_id,
        actor: grant.actor,
        granted: true,
        allowed_actions: grant.actions
      }

      cmd = %{
        id: p["command_id"],
        expected_version: p["expected_version"],
        action: Map.get(@actions, p["action"]),
        reason: p["reason"]
      }

      case Kitchen.apply(state(state, ch, p["merchant_id"], p["order_id"]), trusted, cmd) do
        {:ok, order, :accepted} ->
          {:ok,
           put_in(state, [:merchants, {ch, p["merchant_id"]}, :orders, p["order_id"]], order)}

        {:ok, _, :duplicate} ->
          {:error, {:duplicate_command, p["command_id"]}}

        error ->
          error
      end
    end
  end

  defp admit_one(_, _, _), do: {:error, :unknown_restaurant_event}

  defp cancellation_allowed(delivery, chapter, %{"action" => "cancel"} = p) do
    if Delivery.handoff(delivery, chapter, p["merchant_id"], p["order_id"]),
      do: {:error, :dispatch_custody_reconciliation_required},
      else: :ok
  end

  defp cancellation_allowed(_, _, _), do: :ok

  defp governance(ch, signer, keys) do
    if Map.get(keys[{ch, "governance"}] || %{}, signer.key_id) == signer.pubkey,
      do: :ok,
      else: {:error, :restaurant_governance_not_declared}
  end

  # A device acts only for the merchant it was granted, with its granted key.
  defp device(%{chapter_id: ch, signers: [signer], payload: p}, state, action) do
    merchant = p["merchant_id"]

    with true <- active_device?(state, ch, merchant, signer),
         grant = state.grants[{ch, merchant, signer.key_id}],
         true <- is_nil(action) or action in grant.actions do
      {:ok, grant}
    else
      _ -> {:error, :forbidden}
    end
  end

  defp checkout_menu(nil, payload) do
    if Map.get(payload, "menu_revision", 0) == 0, do: :ok, else: {:error, :stale_menu}
  end

  defp checkout_menu(menu, payload) do
    with true <- payload["menu_revision"] == menu.revision or {:error, :stale_menu},
         true <- payload["currency"] == menu.currency or {:error, :menu_currency_mismatch},
         items = Map.new(menu.items, &{&1["id"], &1}),
         true <-
           Enum.all?(payload["lines"], fn line ->
             case items[line["item_id"]] do
               nil ->
                 false

               item ->
                 line["name"] == item["name"] and line["unit_minor"] == item["price_minor"] and
                   line["discount_minor"] == Map.get(item, "discount_minor", 0) * line["quantity"]
             end
           end) or {:error, :menu_line_mismatch} do
      :ok
    end
  end

  defp merchant(state, ch, m) do
    case get_in(state, [:merchants, {ch, m}]) do
      nil ->
        with {:ok, checkout} <- Placement.new(Kitchen.workflow(), m, %{}),
             do: {:ok, %{checkout: checkout, orders: %{}, index: %{}, details: %{}}}

      merchant ->
        {:ok, merchant}
    end
  end

  defp placed({:ok, checkout, _order, :accepted}, _merchant, _cmd), do: {:ok, checkout}

  defp placed({:ok, _, _, :duplicate}, merchant, cmd),
    do: {:error, {:duplicate_checkout, merchant.index[{cmd.channel, cmd.idempotency_key}]}}

  defp placed(error, _, _), do: error

  defp decode_grant(%{"device_id" => device, "pubkey" => {:bytes, pubkey}} = p) do
    with {:ok, actor} <- lookup(@actors, p["actor"]),
         {:ok, actions} <- decode_actions(p["actions"]) do
      {:ok, %{device_id: device, pubkey: pubkey, actor: actor, actions: actions}}
    else
      _ -> {:error, :invalid_restaurant_grant}
    end
  end

  defp decode_grant(_), do: {:error, :invalid_restaurant_grant}

  defp decode_actions(names) when is_list(names) do
    Enum.reduce_while(names, {:ok, []}, fn name, {:ok, acc} ->
      case lookup(@actions, name) do
        {:ok, action} -> {:cont, {:ok, acc ++ [action]}}
        error -> {:halt, error}
      end
    end)
  end

  defp decode_actions(_), do: :error

  defp decode_checkout(p) do
    with {:ok, channel} <- lookup(@channels, p["channel"]),
         {:ok, fulfillment} <- lookup(@fulfillments, p["fulfillment"]),
         true <- currency?(p["currency"]),
         true <- lines?(p["lines"]),
         {:ok, adjustments} <- adjustments(p["adjustments"]),
         true <- Enum.all?([p["subtotal_minor"], p["total_minor"]], &minor?/1) do
      cmd =
        %{
          cart_id: p["cart_id"],
          channel: channel,
          idempotency_key: p["idempotency_key"],
          fulfillment: fulfillment,
          adjustments: adjustments
        }
        |> then(
          &if(Map.has_key?(p, "delivery"), do: Map.put(&1, :delivery, p["delivery"]), else: &1)
        )

      cart = %{
        principal: p["principal_id"],
        status: :active,
        currency: p["currency"],
        lines: p["lines"]
      }

      snapshot = fn _cart, _cmd ->
        {:ok,
         %{
           lines: p["lines"],
           subtotal: p["subtotal_minor"],
           total: p["total_minor"],
           adjustments: adjustments
         }}
      end

      {:ok, cmd, cart, snapshot}
    else
      _ -> {:error, :invalid_checkout_command}
    end
  end

  defp name?(nil), do: true
  defp name?(name), do: is_binary(name) and String.length(String.trim(name)) in 1..80

  defp currency?(code), do: is_binary(code) and Regex.match?(~r/\A[A-Z]{3}\z/, code)
  defp minor?(n), do: is_integer(n) and n >= 0

  defp lines?(lines) when is_list(lines),
    do:
      Enum.all?(
        lines,
        &match?(
          %{"unit_minor" => u, "quantity" => q, "discount_minor" => d}
          when is_integer(u) and is_integer(q) and q > 0 and is_integer(d),
          &1
        )
      )

  defp lines?(_), do: false

  defp adjustments(%{} = a) do
    if Enum.sort(Map.keys(a)) == Enum.sort(Map.keys(@adjustments)) and
         Enum.all?(Map.values(a), &minor?/1),
       do: {:ok, Map.new(a, fn {k, v} -> {@adjustments[k], v} end)},
       else: :error
  end

  defp adjustments(_), do: :error

  defp lookup(table, key) when is_binary(key), do: Map.fetch(table, key)
  defp lookup(_, _), do: :error
end
