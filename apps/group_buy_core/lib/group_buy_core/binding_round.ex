defmodule GroupBuyCore.BindingRound do
  @moduledoc """
  Pure seller-home projection of a binding **conditional** group-buy pledge.

  A member who signs an authorized pledge agrees *in advance* to buy the
  stated units at the seller's tier rate (never above their explicit price
  ceiling) **if the minimum is met**. No second opt-in is required then.
  When the locally admitted pledge event first crosses the minimum, this
  aggregate activates all still-current pledges as binding obligations.

  Later valid pledges join a bound round as immediately binding. Deeper
  seller-posted volume tiers can only LOWER every member's price, never
  raise it. Buyers cannot withdraw after activation, including after their
  old pledge opt-in deadline passes. Prethreshold withdrawal/expiry removes
  conditional interest without penalty under the campaign's policy.

  The trusted host must verify seller-offer authority, signatures, member
  eligibility, consideration, deadlines, reserves/capacity and local durable
  append before passing events here. An evidence_ref alone is NOT a verified
  contract. This module does not charge, take custody, reserve stock,
  dispatch goods, or adjudicate consumer cancellation rights.
  """

  alias GroupBuyCore, as: Group

  @max 9_007_199_254_740_991
  @schema "bizkit.group-buy.binding-round.v1"
  @pledge_cmd ~w(id expected_version op pledge evidence_ref)a
  @withdraw_cmd ~w(id expected_version op buyer pledge_id evidence_ref)a

  @doc "Create a pure seller-offer-bound conditional pledge round."
  def new(offer, now) do
    case Group.quote(offer, [], now) do
      {:ok, _} ->
        {:ok, %{offer: offer, version: 0, pledges: %{}, activated: nil, seen: %{}}}

      error ->
        error
    end
  end

  @doc """
  Apply a host-authorized pledge or permitted prethreshold withdrawal.
  The threshold crossing and pledge admission occur in ONE state transition;
  no extra seller/buyer signature ceremony is inserted at activation.

  The returned state/event is still a *proposed* signed local-ledger write.
  The host must commit it before treating the obligations as enforceable.
  """
  def apply(state, actor, %{id: id, expected_version: expected, op: _} = command, now)
      when is_integer(now) and now >= 0 do
    with :ok <- state_shape(state),
         :ok <- identifier(id),
         :ok <- command_shape(command) do
      case Map.get(state.seen, id) do
        {^actor, ^command} ->
          {:ok, state, :duplicate}

        nil ->
          with :ok <- version(state.version, expected),
               {:ok, updated} <- transition(state, actor, command, now) do
            {:ok,
             %{
               updated
               | version: state.version + 1,
                 seen: Map.put(state.seen, id, {actor, command})
             }, :accepted}
          end

        _ ->
          {:error, :idempotency_conflict}
      end
    end
  end

  def apply(_, _, _, _), do: {:error, :invalid_binding_command}

  @doc "Reconstruct the conditional/binding round from host-accepted events."
  def replay(initial, events) when is_list(events) do
    Enum.reduce_while(events, {:ok, initial}, fn {actor, command, at}, {:ok, state} ->
      case apply(state, actor, command, at) do
        {:ok, next, _} -> {:cont, {:ok, next}}
        error -> {:halt, error}
      end
    end)
  end

  def replay(_, _), do: {:error, :invalid_events}

  @doc """
  Summarize binding obligations after threshold activation. No re-election
  step exists. Before activation, show signed *conditional* pledges and the
  minimum needed to bind. After activation, pledge expiry does NOT unbind.
  """
  def snapshot(state, now) when is_integer(now) and now >= 0 do
    with :ok <- state_shape(state) do
      if state.activated == nil do
        with {:ok, candidate} <- Group.quote(state.offer, Map.values(state.pledges), now) do
          {:ok,
           %{
             schema: @schema,
             campaign_id: state.offer.id,
             revision: state.version,
             status: :conditional_not_yet_binding,
             pledged_quantity: candidate.active_quantity,
             minimum: hd(state.offer.tiers).min_quantity,
             additional_units_needed:
               max(hd(state.offer.tiers).min_quantity - candidate.active_quantity, 0),
             members: Enum.map(candidate.members, & &1.buyer),
             bound_obligations: [],
             payment_status: :not_collected,
             stock_status: :not_reserved
           }}
        end
      else
        bound_snapshot(state, now)
      end
    end
  end

  def snapshot(_, _), do: {:error, :invalid_binding_round}

  defp transition(state, actor, %{op: :pledge, pledge: pledge, evidence_ref: proof}, now) do
    with :ok <- evidence(proof),
         true <- is_map(pledge) and Map.get(pledge, :buyer) == actor,
         true <- is_nil(state.activated) or now < state.offer.expires_at,
         :ok <- validate_pledge_price(pledge, state.offer),
         :ok <- unexpired_pledge(pledge, now),
         :ok <- check_new_member(state, actor, now) do
      current =
        if state.activated == nil,
          do: Enum.reject(Map.values(state.pledges), &(&1.expires_at <= now)),
          else: Map.values(state.pledges)

      new_pledges = current ++ [pledge]
      # For a previously bound round, the expired opt-in cutoff is not a
      # cancellation right. Use the original validated terms while the
      # seller campaign is still open; do not silently drop bound members.
      validation =
        if state.activated == nil,
          do: Group.quote(state.offer, new_pledges, now),
          else: validate_join(state.offer, new_pledges, now)

      case validation do
        {:ok, candidate} ->
          pledges = Map.new(new_pledges, &{&1.buyer, &1})

          activated =
            if state.activated != nil do
              state.activated
            else
              if candidate.active_quantity >= hd(state.offer.tiers).min_quantity do
                %{
                  at: now,
                  first_threshold: hd(state.offer.tiers).min_quantity,
                  initiating_quote_hash: candidate.quote_hash
                }
              else
                nil
              end
            end

          {:ok, %{state | pledges: pledges, activated: activated}}

        {:error, _} = error ->
          error
      end
    else
      false -> {:error, :unauthorized_or_expired_pledge}
      {:error, _} = error -> error
      _ -> {:error, :invalid_pledge}
    end
  end

  defp transition(%{activated: activated}, _, %{op: :withdraw}, _now)
       when not is_nil(activated),
       do: {:error, :binding_pledge_cannot_be_withdrawn}

  defp transition(
         state,
         actor,
         %{op: :withdraw, buyer: buyer, pledge_id: pledge_id, evidence_ref: proof},
         _now
       ) do
    with true <- actor == buyer,
         :ok <- evidence(proof),
         %{id: ^pledge_id} <- Map.get(state.pledges, buyer) do
      {:ok, %{state | pledges: Map.delete(state.pledges, buyer)}}
    else
      _ -> {:error, :unknown_or_unauthorized_pledge}
    end
  end

  defp transition(_, _, _, _), do: {:error, :invalid_binding_command}

  # Existing bound participants survive their old opt-in deadline, but a NEW
  # pledge must still be current when admitted, including late active joins.
  defp unexpired_pledge(%{expires_at: expiry}, now) when is_integer(expiry) and expiry > now,
    do: :ok

  defp unexpired_pledge(_, _), do: {:error, :expired_pledge}

  defp validate_pledge_price(pledge, offer) do
    # Every accepted pledge must be satisfiable if the **first** tier
    # activates. A buyer who only accepts a deeper tier needs a new round
    # with terms reflecting that constraint.
    case pledge do
      %{max_group_unit_minor: cap}
      when is_integer(cap) and cap >= 1 and cap <= @max ->
        if cap >= hd(offer.tiers).unit_minor,
          do: :ok,
          else: {:error, :price_ceiling_below_activation_tier}

      _ ->
        {:error, :invalid_pledge}
    end
  end

  defp check_new_member(state, actor, now) do
    if state.activated != nil and Map.has_key?(state.pledges, actor) do
      {:error, :already_binding}
    else
      case Map.get(state.pledges, actor) do
        nil -> :ok
        %{expires_at: expires} when expires <= now and is_nil(state.activated) -> :ok
        _ -> {:error, :duplicate_member_pledge}
      end
    end
  end

  # Group.quote always filters expired pledges. Existing binding obligations
  # may not be erased by that filter. Reconstruct a temporary validation copy
  # with continuing opt-in validity, without changing original signed terms.
  defp validate_join(offer, pledges, now) do
    extended =
      Enum.map(pledges, fn pledge ->
        if pledge.expires_at <= now, do: %{pledge | expires_at: offer.expires_at}, else: pledge
      end)

    Group.quote(offer, extended, now)
  end

  defp bound_snapshot(state, now) do
    offer = state.offer
    pledges = state.pledges |> Map.values() |> Enum.sort_by(& &1.id)
    qty = Enum.sum(Enum.map(pledges, & &1.quantity))

    tier =
      offer.tiers
      |> Enum.filter(&(&1.min_quantity <= qty))
      |> List.last()

    if tier == nil do
      {:error, :binding_invariant_violated}
    else
      members =
        Enum.map(pledges, fn p ->
          %{
            buyer: p.buyer,
            pledge_id: p.id,
            quantity: p.quantity,
            unit_minor: tier.unit_minor,
            due_minor: p.quantity * tier.unit_minor,
            max_group_unit_minor: p.max_group_unit_minor,
            obligation: :binding_automatically_at_threshold,
            payment: :not_collected,
            inventory: :not_reserved
          }
        end)

      total = Enum.sum(Enum.map(members, & &1.due_minor))

      if total > @max or Enum.any?(members, &(&1.due_minor > @max)) do
        {:error, :amount_overflow}
      else
        digest_fields =
          [
            @schema,
            offer.id,
            Integer.to_string(offer.revision),
            Integer.to_string(state.activated.at),
            state.activated.initiating_quote_hash,
            Integer.to_string(qty),
            Integer.to_string(tier.unit_minor)
          ] ++
            Enum.flat_map(members, fn member ->
              [
                member.buyer,
                member.pledge_id,
                Integer.to_string(member.quantity),
                Integer.to_string(member.max_group_unit_minor),
                Integer.to_string(member.due_minor)
              ]
            end)

        {:ok,
         %{
           schema: @schema,
           campaign_id: offer.id,
           revision: state.version,
           status: :binding_threshold_activated,
           threshold_crossed_at: state.activated.at,
           initiating_quote_hash: state.activated.initiating_quote_hash,
           contracted_quantity: qty,
           currency: offer.currency,
           sku: offer.sku,
           unit: offer.unit,
           group_unit_minor: tier.unit_minor,
           tier_minimum: tier.min_quantity,
           members: members,
           total_due_minor: total,
           terms_hash: digest(digest_fields),
           offer_expired: now >= offer.expires_at,
           payment_status: :not_collected,
           stock_status: :not_reserved,
           obligations: :require_signed_seller_home_host_admission
         }}
      end
    end
  end

  defp digest(fields) do
    encoded =
      Enum.map_join(fields, "", fn field ->
        Integer.to_string(byte_size(field)) <> ":" <> field
      end)

    :crypto.hash(:sha256, encoded) |> Base.encode16(case: :lower)
  end

  defp state_shape(%{
         offer: %{tiers: [_ | _]},
         version: version,
         pledges: pledges,
         activated: activated,
         seen: seen
       })
       when is_integer(version) and version >= 0 and is_map(pledges) and is_map(seen) and
              (is_nil(activated) or is_map(activated)),
       do: :ok

  defp state_shape(_), do: {:error, :invalid_binding_round}
  defp command_shape(%{op: :pledge} = c), do: exact(c, @pledge_cmd)
  defp command_shape(%{op: :withdraw} = c), do: exact(c, @withdraw_cmd)
  defp command_shape(_), do: {:error, :invalid_binding_command}

  defp exact(map, keys) do
    if Enum.sort(Map.keys(map)) == Enum.sort(keys),
      do: :ok,
      else: {:error, :invalid_binding_command}
  end

  defp version(rev, rev), do: :ok
  defp version(_, _), do: {:error, :stale_binding_version}

  defp identifier(v) when is_binary(v) and byte_size(v) in 1..256,
    do: if(String.trim(v) != "", do: :ok, else: {:error, :invalid_identifier})

  defp identifier(_), do: {:error, :invalid_identifier}
  defp evidence(v), do: identifier(v)
end
