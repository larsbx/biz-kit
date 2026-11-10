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

  The delivery handoff (`RestaurantCore.Delivery`, over the I8 relation in
  `RestaurantCore.Coupling`):

    * `RestaurantTransportGrantedV1`, signed by a declared governance key,
      binds a Dispatch transport key to a merchant and a Dispatch identity. It
      shares no key with any restaurant device or declared role key.
    * `RestaurantTransportRequestedV1`, signed by a device that may
      `mark_ready`, opens a FulfillmentCore request for a ready delivery order.
    * `RestaurantTransportCancelRequestedV1`, signed by a device that may
      `cancel`, withdraws it (FulfillmentCore's commerce cancel).
    * `RestaurantTransportStepV1`, signed under `dispatch_transport` by a
      granted transport key (after acceptance, only the accepting Dispatch's),
      is one FulfillmentCore dispatch op; pickup, delivery and failure in
      transit move the order through `OrderCore.Transport`. Delivery and
      failure carry a proof digest no other step has cited.

  The trusted context is derived from the grant, never from the payload, and
  the outcome is exactly the reducers' outcome (`admit/3` serves both check and
  fold), with one refinement: a step `Kitchen.apply/3` accepts is refused
  `:transport_pending` while the order's transport is live, and transport
  events admit only their Coupling row's target. Every event is a business
  fact: none asserts payment or settlement. Money is Hawala's: nothing here
  computes, accepts or settles an amount.
  """

  alias OrderCore.Placement
  alias RestaurantCore.{Coupling, Delivery, Kitchen}

  @grant "RestaurantDeviceGrantedV1"
  @placed "RestaurantOrderPlacedV1"
  @step "RestaurantOrderStepV1"
  @transport_grant "RestaurantTransportGrantedV1"
  @request "RestaurantTransportRequestedV1"
  @withdraw "RestaurantTransportCancelRequestedV1"
  @transport_step "RestaurantTransportStepV1"
  @device "restaurant_device"
  @transport "dispatch_transport"
  @order_stream ["merchant_id", "order_id"]

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
        ),
      @transport_grant =>
        spec("governance", "restaurant_transport_keys", ["merchant_id"], %{
          "merchant_id" => :string,
          "dispatch_id" => :string,
          "key_id" => :string,
          "pubkey" => :pubkey
        }),
      @request =>
        spec(@device, "restaurant_orders", @order_stream, %{
          "merchant_id" => :string,
          "order_id" => :string,
          "request_id" => :string,
          "expected_version" => :int
        }),
      @withdraw =>
        spec(@device, "restaurant_orders", @order_stream, %{
          "merchant_id" => :string,
          "order_id" => :string,
          "request_id" => :string,
          "command_id" => :string,
          "expected_version" => :int,
          "reason" => :string
        }),
      @transport_step =>
        spec(
          @transport,
          "restaurant_orders",
          @order_stream,
          %{
            "merchant_id" => :string,
            "order_id" => :string,
            "request_id" => :string,
            "step_id" => :string,
            "expected_version" => :int,
            "op" => :string
          },
          %{"transport_ref" => :string, "reason" => :string, "proof" => :hash}
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

  @doc """
  The empty state. `transport_keys` maps `{chapter, merchant, key_id}` to a
  Dispatch identity and pubkey; `handoffs` holds each delivery order's current
  request; `requests` (request ids) and `proofs` (cited digests) only grow.
  """
  def init,
    do: %{
      grants: %{},
      merchants: %{},
      transport_keys: %{},
      handoffs: %{},
      requests: %{},
      proofs: %{}
    }

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

  @doc "A delivery order's current handoff, or nil."
  def handoff(state, chapter, merchant, order_id),
    do: state.handoffs[{chapter, merchant, order_id}]

  @doc """
  Whether `pubkey` (raw or `{:bytes, _}`) is any granted Dispatch transport
  key, in any chapter. The substrate refuses to declare such a key as a role
  key, as a transport grant refuses a declared role key.
  """
  def transport_pubkey?(state, {:bytes, pubkey}), do: transport_pubkey?(state, pubkey)

  def transport_pubkey?(state, pubkey),
    do: Enum.any?(Map.values(state.transport_keys), &(&1.pubkey == pubkey))

  @doc "Whether governance has granted the merchant any Dispatch transport key."
  def transport?(state, chapter, merchant),
    do: Enum.any?(Map.keys(state.transport_keys), &match?({^chapter, ^merchant, _}, &1))

  @doc """
  A merchant's orders, oldest first by id: each order's lifecycle (`state`,
  `version`, the `actions` it can take now) joined with its signed snapshot.
  A delivery order also carries its signed `delivery` details, its `handoff`
  (nil before a request) and the `handoff_actions` its pair allows; its
  `actions` drop `:cancel` while transport is live.
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
          |> Map.merge(%{id: id, state: order.state, version: order.version})
          |> Map.merge(transport_view(state, chapter, merchant, order))
          |> Map.merge(Map.fetch!(details, id))
        end)
        |> Enum.sort_by(& &1.id)
    end
  end

  defp transport_view(state, chapter, merchant, order) do
    handoff = handoff(state, chapter, merchant, order.id)
    {s, view} = Delivery.pair(order, handoff)
    live? = view in Coupling.live()

    handoff_actions =
      cond do
        s != :ready or order.fulfillment != :delivery ->
          []

        # Not after a confirmed withdrawal: the restaurant asked to cancel, so the
        # board offers Cancel to finish (the ledger would still admit a request).
        view in [:none, :rejected, :failed_before_pickup] ->
          if transport?(state, chapter, merchant), do: [:request_transport], else: []

        view in [:requested, :accepted] ->
          [:withdraw_transport]

        true ->
          []
      end

    %{
      actions: Kitchen.available_actions(order) -- if(live?, do: [:cancel], else: []),
      handoff: handoff && summary(handoff, view),
      handoff_actions: handoff_actions
    }
  end

  defp summary(%{fc: fc} = handoff, view),
    do: %{
      request_id: fc.request_id,
      view: view,
      version: fc.version,
      transport_ref: fc.transport_ref,
      accepted_by: handoff.accepted_by,
      reason: handoff.reason,
      proof: handoff.proof && Base.encode16(handoff.proof, case: :lower)
    }

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
           ),
         :ok <-
           separate([
             Map.has_key?(state.transport_keys, id),
             transport_pubkey?(state, grant.pubkey)
           ]) do
      {:ok, put_in(state, [:grants, id], grant)}
    end
  end

  defp admit_one(
         %{type: @transport_grant, chapter_id: ch, signers: [signer], payload: p},
         keys,
         state
       ) do
    id = {ch, p["merchant_id"], p["key_id"]}

    with :ok <- governance(ch, signer, keys),
         {:ok, key} <- decode_transport_grant(p),
         :ok <-
           if(Map.has_key?(state.transport_keys, id),
             do: {:error, :transport_key_already_granted},
             else: :ok
           ),
         :ok <-
           separate([
             Map.has_key?(state.grants, id),
             Enum.any?(Map.values(state.grants), &(&1.pubkey == key.pubkey)),
             Enum.any?(Map.values(keys), &(key.pubkey in Map.values(&1))),
             Enum.any?(
               Map.values(state.transport_keys),
               &(&1.pubkey == key.pubkey and &1.dispatch_id != key.dispatch_id)
             )
           ]) do
      {:ok, put_in(state, [:transport_keys, id], key)}
    end
  end

  defp admit_one(%{type: @request, chapter_id: ch, payload: p} = env, _keys, state) do
    {m, o, rid} = {p["merchant_id"], p["order_id"], p["request_id"]}

    with {:ok, grant} <- device(env, state, nil),
         :ok <- may(grant, p, :mark_ready),
         {:ok, order} <- order(state, ch, m, o),
         :ok <- if(identifier?(rid), do: :ok, else: {:error, :invalid_transport_request}),
         :ok <- delivery(order),
         request = %{
           order_id: o,
           device_id: grant.device_id,
           expected_version: p["expected_version"]
         },
         :ok <-
           (case state.requests[{ch, m, rid}] do
              nil -> :ok
              ^request -> {:error, {:duplicate_request, rid}}
              _ -> {:error, :request_id_conflict}
            end),
         :ok <-
           if(p["expected_version"] === order.version,
             do: :ok,
             else: {:error, :stale_order_version}
           ),
         :ok <- if(transport?(state, ch, m), do: :ok, else: {:error, :no_transport_authority}),
         :ok <- address(get_in(state, [:merchants, {ch, m}, :details, o])),
         {:ok, fc} <- Delivery.request(order, handoff(state, ch, m, o), rid) do
      handoff = %{
        fc: fc,
        requested_by: grant.device_id,
        accepted_by: nil,
        reason: nil,
        proof: nil
      }

      {:ok,
       state
       |> put_in([:handoffs, {ch, m, o}], handoff)
       |> put_in([:requests, {ch, m, rid}], request)}
    end
  end

  defp admit_one(%{type: @withdraw, chapter_id: ch, payload: p} = env, _keys, state) do
    {m, o} = {p["merchant_id"], p["order_id"]}

    with {:ok, grant} <- device(env, state, nil),
         :ok <- may(grant, p, :cancel),
         {:ok, order} <- order(state, ch, m, o),
         {:ok, handoff} <-
           current(handoff(state, ch, m, o), p["request_id"], :unknown_handoff, :unknown_handoff),
         :ok <- if(p["reason"] != "", do: :ok, else: {:error, :reason_required}),
         event = %{
           id: p["command_id"],
           expected_version: p["expected_version"],
           op: :cancel,
           reason: p["reason"]
         },
         {:ok, fc} <- Delivery.withdraw(order, handoff, event) do
      {:ok, put_in(state, [:handoffs, {ch, m, o}], %{handoff | fc: fc})}
    end
  end

  defp admit_one(
         %{type: @transport_step, chapter_id: ch, signers: [signer], payload: p},
         _keys,
         state
       ) do
    {m, o} = {p["merchant_id"], p["order_id"]}

    with {:ok, key} <- transport_key(state, {ch, m, signer.key_id}, signer.pubkey),
         {:ok, event, digest} <- decode_step(p),
         {:ok, handoff} <-
           current(
             handoff(state, ch, m, o),
             p["request_id"],
             :no_transport_request,
             :unknown_request
           ),
         :ok <-
           if(handoff.accepted_by in [nil, key.dispatch_id], do: :ok, else: {:error, :forbidden}),
         {:ok, order} <- order(state, ch, m, o),
         {:ok, next, fc} <- Delivery.dispatch(order, handoff, key.dispatch_id, event),
         :ok <- if(Map.has_key?(state.proofs, digest), do: {:error, :proof_reused}, else: :ok) do
      handoff = %{
        handoff
        | fc: fc,
          accepted_by: if(event.op == :accept, do: key.dispatch_id, else: handoff.accepted_by),
          reason: Map.get(event, :reason, handoff.reason),
          proof: digest || handoff.proof
      }

      state =
        state
        |> put_in([:handoffs, {ch, m, o}], handoff)
        |> put_in([:merchants, {ch, m}, :orders, o], next)

      {:ok,
       if(digest,
         do:
           put_in(state, [:proofs, digest], %{
             chapter: ch,
             merchant: m,
             order_id: o,
             request_id: fc.request_id
           }),
         else: state
       )}
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
         details: Map.put(merchant.details, p["order_id"], details(cmd.fulfillment, p)),
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

      order = state(state, ch, p["merchant_id"], p["order_id"])

      case Kitchen.apply(order, trusted, cmd) do
        {:ok, next, :accepted} ->
          with :ok <-
                 Delivery.guard_step(
                   order,
                   next,
                   handoff(state, ch, p["merchant_id"], p["order_id"]),
                   cmd.action
                 ),
               do:
                 {:ok,
                  put_in(
                    state,
                    [:merchants, {ch, p["merchant_id"]}, :orders, p["order_id"]],
                    next
                  )}

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

  # The grant's own authority for an action, under the kitchen's roles.
  defp may(grant, p, action) do
    trusted = %{
      merchant: p["merchant_id"],
      order_id: p["order_id"],
      principal: grant.device_id,
      actor: grant.actor,
      granted: true,
      allowed_actions: grant.actions
    }

    if Kitchen.authorized?(trusted, action), do: :ok, else: {:error, :forbidden}
  end

  # A Dispatch transport key acts only for the merchant it was granted, with its granted key.
  defp transport_key(state, id, pubkey) do
    case state.transport_keys[id] do
      %{pubkey: ^pubkey} = key -> {:ok, key}
      _ -> {:error, :forbidden}
    end
  end

  defp order(state, ch, m, o) do
    case state(state, ch, m, o) do
      nil -> {:error, :forbidden}
      order -> {:ok, order}
    end
  end

  defp delivery(%{fulfillment: :delivery}), do: :ok
  defp delivery(_), do: {:error, :not_a_delivery_order}

  defp current(nil, _request_id, missing, _other), do: {:error, missing}
  defp current(%{fc: %{request_id: id}} = handoff, id, _missing, _other), do: {:ok, handoff}
  defp current(_handoff, _request_id, _missing, other), do: {:error, other}

  defp separate(collisions),
    do: if(Enum.any?(collisions), do: {:error, :key_not_separate}, else: :ok)

  defp details(:delivery, p), do: %{pickup_name: p["pickup_name"], delivery: p["delivery"]}
  defp details(_, p), do: %{pickup_name: p["pickup_name"]}

  defp address(%{delivery: %{"address" => a}}) when is_binary(a) do
    if String.trim(a) != "" and String.length(a) <= 200,
      do: :ok,
      else: {:error, :delivery_address_required}
  end

  defp address(_), do: {:error, :delivery_address_required}

  defp identifier?(v), do: is_binary(v) and byte_size(v) in 1..128

  defp decode_transport_grant(%{"pubkey" => {:bytes, <<_::256>> = pubkey}} = p) do
    if Enum.all?([p["merchant_id"], p["dispatch_id"], p["key_id"]], &identifier?/1),
      do: {:ok, %{dispatch_id: p["dispatch_id"], pubkey: pubkey}},
      else: {:error, :invalid_transport_grant}
  end

  defp decode_transport_grant(_), do: {:error, :invalid_transport_grant}

  # The op and exactly its fields; the proof digest travels to FulfillmentCore as hex.
  defp decode_step(p) do
    present = Enum.filter(["proof", "reason", "transport_ref"], &Map.has_key?(p, &1))

    with {:ok, op, fields} <- Coupling.dispatch_fields(p["op"]),
         :ok <-
           if("proof" in fields and "proof" not in present,
             do: {:error, :proof_required},
             else: :ok
           ),
         true <- present == fields or {:error, :invalid_transport_step} do
      digest = with {:bytes, d} <- p["proof"], do: d

      event =
        %{id: p["step_id"], expected_version: p["expected_version"], op: op}
        |> then(
          &if(p["transport_ref"], do: Map.put(&1, :transport_ref, p["transport_ref"]), else: &1)
        )
        |> then(&if(p["reason"], do: Map.put(&1, :reason, p["reason"]), else: &1))
        |> then(
          &if(digest, do: Map.put(&1, :proof_ref, Base.encode16(digest, case: :lower)), else: &1)
        )

      {:ok, event, digest}
    else
      :error -> {:error, :invalid_transport_step}
      error -> error
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
