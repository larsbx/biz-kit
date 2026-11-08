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
  alias RestaurantCore.Kitchen

  @grant "RestaurantDeviceGrantedV1"
  @placed "RestaurantOrderPlacedV1"
  @step "RestaurantOrderStepV1"
  @device "restaurant_device"

  @actors Map.new(~w(admin staff system)a, &{Atom.to_string(&1), &1})
  @actions Map.new([:checkout | Map.keys(Kitchen.workflow().actions)], &{Atom.to_string(&1), &1})
  @channels Map.new(Placement.channels(), &{Atom.to_string(&1), &1})
  @fulfillments Map.new(Kitchen.workflow().fulfillments, &{Atom.to_string(&1), &1})
  @adjustments Map.new(~w(discount_total tax_total delivery_fee tip)a, &{Atom.to_string(&1), &1})

  def event_types do
    %{
      @grant =>
        spec("governance", "restaurant_devices", ["merchant_id"], %{
          "merchant_id" => :string,
          "device_id" => :string,
          "key_id" => :string,
          "pubkey" => :pubkey,
          "actor" => :string,
          "actions" => :any
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
          %{"delivery" => :any, "pickup_name" => :string}
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
          %{"reason" => :string}
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

  def init, do: %{grants: %{}, merchants: %{}}

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
            actions: Kitchen.available_actions(order)
          })
          |> Map.merge(Map.fetch!(details, id))
        end)
        |> Enum.sort_by(& &1.id)
    end
  end

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
           placed(Placement.apply(projection, trusted, cmd, snapshot), merchant, cmd),
         {:ok, order} <- Kitchen.new(p["merchant_id"], p["order_id"], cmd.fulfillment) do
      {:ok,
       put_in(state, [:merchants, {ch, p["merchant_id"]}], %{
         checkout: checkout,
         orders: Map.put(merchant.orders, p["order_id"], order),
         details: Map.put(merchant.details, p["order_id"], %{pickup_name: p["pickup_name"]}),
         index: Map.put(merchant.index, {cmd.channel, cmd.idempotency_key}, p["order_id"])
       })}
    end
  end

  defp admit_one(%{type: @step, chapter_id: ch, payload: p} = env, _keys, state) do
    with {:ok, grant} <- device(env, state, nil) do
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

  defp governance(ch, signer, keys) do
    if Map.get(keys[{ch, "governance"}] || %{}, signer.key_id) == signer.pubkey,
      do: :ok,
      else: {:error, :restaurant_governance_not_declared}
  end

  # A device acts only for the merchant it was granted, with its granted key.
  defp device(%{chapter_id: ch, signers: [signer], payload: p}, state, action) do
    case state.grants[{ch, p["merchant_id"], signer.key_id}] do
      %{pubkey: pubkey} = grant when pubkey == signer.pubkey ->
        if action == nil or action in grant.actions, do: {:ok, grant}, else: {:error, :forbidden}

      _ ->
        {:error, :forbidden}
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
         true <- Enum.all?([p["subtotal_minor"], p["total_minor"]], &minor?/1),
         true <- adds_up?(p["lines"], p["subtotal_minor"], p["total_minor"], adjustments) do
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

  # Pricing's I₂ on the signed integers: each 0 ≤ dᵢ ≤ uᵢ·qᵢ, the subtotal is
  # Σ (uᵢ·qᵢ − dᵢ) and the total is subtotal − discount_total + tax_total +
  # delivery_fee + tip. Admission still loads no money stack.
  defp adds_up?(lines, subtotal, total, adj) do
    bases = Enum.map(lines, &{&1["unit_minor"] * &1["quantity"], &1["discount_minor"]})

    Enum.all?(bases, fn {base, d} -> 0 <= d and d <= base end) and
      subtotal == Enum.sum(for {base, d} <- bases, do: base - d) and
      total == subtotal - adj.discount_total + adj.tax_total + adj.delivery_fee + adj.tip
  end

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
