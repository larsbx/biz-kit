defmodule GroupBuyCore.Contracted do
  @moduledoc """
  Pure replayable *contracted-demand* aggregate for a private members-only
  group-buy campaign. Unlike an interest/pledge preview, price tiers become
  eligible only after the trusted seller-home host locally admits individual
  member purchase commitments.

  The host MUST authenticate the member's contractual signature, its
  membership grant, the seller's signed price schedule, authority/expiry and
  append the accepted command to its local durable signed ledger. A caller-
  asserted evidence_ref or actor is not proof of any of these conditions.
  Nothing in this module collects payment or reserves physical inventory.
  """

  alias GroupBuyCore, as: G

  @max 9_007_199_254_740_991
  @schema "bizkit.group-buy.contracted.v1"
  @contract_keys ~w(id expected_version op buyer offer_id offer_revision contract_id quantity max_group_unit_minor expires_at evidence_ref)a
  @withdraw_keys ~w(id expected_version op buyer contract_id evidence_ref)a
  @seal_keys ~w(id expected_version op expected_quote_hash evidence_ref)a

  @doc "Create a seller-home local aggregate from a validated but still private offer."
  def new(offer, now) do
    case G.quote(offer, [], now) do
      {:ok, _} ->
        {:ok,
         %{
           offer: offer,
           version: 0,
           contracts: %{},
           seen: %{},
           sealed: nil
         }}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Apply a HOST-AUTHORIZED command to a pure in-memory projection.

  Only :contract events accepted by this trusted local admission boundary
  count toward a discount threshold. :withdraw is only a pre-seal proposed
  withdrawal and still requires host verification of lawful withdrawal rights.
  :seal is seller-home admission of an immutable qualifying quote, but not
  payment authorization or proof that all counterparties signed.
  """
  def apply(state, actor, command, now)
      when is_map(command) and is_integer(now) and now >= 0 do
    with :ok <- state_shape(state),
         :ok <- command_shape(command),
         :ok <- identifier(command.id) do
      case Map.get(state.seen, command.id) do
        {^actor, ^command} ->
          {:ok, state, :duplicate}

        nil ->
          with :ok <- version(state, command.expected_version),
               {:ok, updated} <- transition(state, actor, command, now) do
            {:ok,
             %{
               updated
               | version: state.version + 1,
                 seen: Map.put(state.seen, command.id, {actor, command})
             }, :accepted}
          end

        _ ->
          {:error, :idempotency_conflict}
      end
    end
  end

  def apply(_, _, _, _), do: {:error, :invalid_contract_command}

  @doc "Reconstruct a projected contract history using already authorized event producers."
  def replay(initial, steps) when is_list(steps) do
    Enum.reduce_while(steps, {:ok, initial}, fn {actor, command, now}, {:ok, state} ->
      case apply(state, actor, command, now) do
        {:ok, next, _} -> {:cont, {:ok, next}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  def replay(_, _), do: {:error, :invalid_replay}

  @doc """
  Quote the best currently **contracted** tier using seller-home accepted
  contracts only; projected pledges play no role. If the final tier exceeds
  any member's signed maximum, the quote refuses rather than treating their
  conditional interest as an affordable contract.
  """
  def quote(state, now) when is_integer(now) and now >= 0 do
    with :ok <- state_shape(state),
         {:ok, _} <- G.quote(state.offer, [], now) do
      active =
        state.contracts
        |> Map.values()
        |> Enum.filter(&(&1.expires_at > now))
        |> Enum.sort_by(& &1.contract_id)

      amount = Enum.sum(Enum.map(active, & &1.quantity))

      if amount > state.offer.capacity do
        {:error, :oversubscribed}
      else
        tier =
          state.offer.tiers
          |> Enum.filter(&(&1.min_quantity <= amount))
          |> List.last()

        with :ok <- check_ceiling(active, tier),
             {:ok, rows} <- member_rows(state.offer, active, tier) do
          next_tier = Enum.find(state.offer.tiers, &(&1.min_quantity > amount))

          expires_at =
            Enum.min([state.offer.expires_at | Enum.map(active, & &1.expires_at)])

          fields =
            [@schema, state.offer.id, Integer.to_string(state.offer.revision)] ++
              offer_fields(state.offer) ++
              [Integer.to_string(length(active))] ++
              Enum.flat_map(active, &contract_fields/1) ++
              [if(tier, do: Integer.to_string(tier.min_quantity), else: "none")]

          {:ok,
           %{
             schema: @schema,
             campaign_id: state.offer.id,
             seller: state.offer.seller,
             sku: state.offer.sku,
             unit: state.offer.unit,
             currency: state.offer.currency,
             quote_hash: digest(fields),
             active_contracts: active,
             contracted_quantity: amount,
             solo_unit_minor: state.offer.solo_unit_minor,
             unlocked_group_unit_minor: if(tier, do: tier.unit_minor, else: nil),
             unlocked_tier_minimum: if(tier, do: tier.min_quantity, else: nil),
             next_tier:
               if(next_tier,
                 do: %{
                   minimum: next_tier.min_quantity,
                   more_units_needed: next_tier.min_quantity - amount,
                   unit_minor: next_tier.unit_minor
                 },
                 else: nil
               ),
             members: rows,
             expires_at: expires_at,
             status:
               if(tier,
                 do: :contracted_threshold_reached_pending_stock_and_payment,
                 else: :contracted_units_below_minimum
               ),
             sealed: state.sealed != nil,
             contract_status: :host_admitted_event_projection,
             payment_status: :not_authorized_or_collected,
             inventory_status: :not_reserved,
             fulfillment_status: :not_requested
           }}
        end
      end
    end
  end

  def quote(_, _), do: {:error, :invalid_contract_state}

  @doc "Validate the immutable seller-sealed terms against the accepted local aggregate."
  def sealed_quote(state, now) do
    with :ok <- state_shape(state),
         true <- state.sealed != nil,
         {:ok, quote} <- __MODULE__.quote(state, now),
         true <- quote.quote_hash == state.sealed.quote_hash,
         true <- quote.status == :contracted_threshold_reached_pending_stock_and_payment do
      {:ok, quote}
    else
      _ -> {:error, :not_currently_sealed}
    end
  end

  defp state_shape(%{
         offer: %{id: _},
         version: version,
         contracts: contracts,
         seen: seen,
         sealed: sealed
       })
       when is_integer(version) and version >= 0 and is_map(contracts) and
              is_map(seen) and (is_nil(sealed) or is_map(sealed)),
       do: :ok

  defp state_shape(_), do: {:error, :invalid_contract_state}

  defp command_shape(%{op: :contract} = c),
    do: exact_keys(c, @contract_keys)

  defp command_shape(%{op: :withdraw} = c),
    do: exact_keys(c, @withdraw_keys)

  defp command_shape(%{op: :seal} = c),
    do: exact_keys(c, @seal_keys)

  defp command_shape(_), do: {:error, :invalid_contract_command}

  defp exact_keys(map, keys) do
    if Enum.sort(Map.keys(map)) == Enum.sort(keys),
      do: :ok,
      else: {:error, :invalid_contract_command}
  end

  defp version(%{version: revision}, revision), do: :ok
  defp version(_, _), do: {:error, :stale_contract_version}

  defp transition(%{sealed: sealed}, _, _, _) when not is_nil(sealed),
    do: {:error, :campaign_sealed}

  defp transition(state, actor, %{op: :contract} = c, now) do
    seller = state.offer.seller

    with true <- actor == c.buyer and actor != seller,
         true <- public_id?(actor),
         true <- public_id?(c.offer_id) and c.offer_id == state.offer.id,
         true <- c.offer_revision == state.offer.revision,
         :ok <- identifier(c.contract_id),
         :ok <- evidence(c.evidence_ref),
         true <- positive(c.quantity) and positive(c.max_group_unit_minor),
         true <-
           is_integer(c.expires_at) and c.expires_at > now and
             c.expires_at <= state.offer.expires_at,
         false <- Map.has_key?(state.contracts, actor),
         false <- Enum.any?(Map.values(state.contracts), &(&1.contract_id == c.contract_id)),
         true <-
           Enum.sum(Enum.map(Map.values(state.contracts), & &1.quantity)) +
             c.quantity <= state.offer.capacity do
      record = %{
        contract_id: c.contract_id,
        buyer: actor,
        quantity: c.quantity,
        max_group_unit_minor: c.max_group_unit_minor,
        expires_at: c.expires_at,
        evidence_ref: c.evidence_ref
      }

      {:ok, %{state | contracts: Map.put(state.contracts, actor, record)}}
    else
      false -> {:error, :invalid_or_duplicate_contract}
      _ -> {:error, :invalid_or_duplicate_contract}
    end
  end

  defp transition(state, actor, %{op: :withdraw} = c, _now) do
    with true <- actor == c.buyer and public_id?(actor),
         :ok <- identifier(c.contract_id),
         :ok <- evidence(c.evidence_ref),
         %{contract_id: ref} <- Map.get(state.contracts, actor),
         true <- ref == c.contract_id do
      {:ok, %{state | contracts: Map.delete(state.contracts, actor)}}
    else
      _ -> {:error, :unknown_or_unauthorized_contract}
    end
  end

  defp transition(state, actor, %{op: :seal} = c, now) do
    with true <- actor == state.offer.seller,
         :ok <- evidence(c.evidence_ref),
         true <- is_binary(c.expected_quote_hash),
         {:ok, quotation} <- __MODULE__.quote(state, now),
         true <- quotation.status == :contracted_threshold_reached_pending_stock_and_payment,
         true <- quotation.quote_hash == c.expected_quote_hash do
      {:ok,
       %{
         state
         | sealed: %{
             quote_hash: quotation.quote_hash,
             evidence_ref: c.evidence_ref,
             contracted_quantity: quotation.contracted_quantity
           }
       }}
    else
      _ -> {:error, :not_ready_to_seal}
    end
  end

  defp transition(_, _, _, _), do: {:error, :invalid_contract_command}

  defp check_ceiling(_, nil), do: :ok

  defp check_ceiling(contracts, tier) do
    if Enum.all?(contracts, &(&1.max_group_unit_minor >= tier.unit_minor)),
      do: :ok,
      else: {:error, :contract_price_ceiling_exceeded}
  end

  defp member_rows(offer, contracts, tier) do
    rows =
      Enum.map(contracts, fn c ->
        cash = c.quantity * offer.solo_unit_minor
        group = if tier, do: c.quantity * tier.unit_minor, else: nil

        %{
          buyer: c.buyer,
          contract_id: c.contract_id,
          quantity: c.quantity,
          cash_minor: cash,
          group_minor: group,
          savings_minor: if(group, do: cash - group, else: nil),
          election: :awaiting_individual_payment_authorization
        }
      end)

    if Enum.all?(rows, fn row ->
         row.cash_minor <= @max and
           (is_nil(row.group_minor) or row.group_minor <= @max)
       end) and Enum.sum(Enum.map(rows, & &1.cash_minor)) <= @max and
         Enum.sum(Enum.map(rows, &if(is_nil(&1.group_minor), do: 0, else: &1.group_minor))) <=
           @max do
      {:ok, rows}
    else
      {:error, :amount_overflow}
    end
  end

  defp offer_fields(o) do
    [
      o.seller,
      o.sku,
      o.unit,
      o.currency,
      Integer.to_string(o.expires_at),
      Integer.to_string(o.capacity),
      Integer.to_string(o.solo_unit_minor),
      Integer.to_string(length(o.tiers))
    ] ++
      Enum.flat_map(o.tiers, fn t ->
        [Integer.to_string(t.min_quantity), Integer.to_string(t.unit_minor)]
      end)
  end

  defp contract_fields(c) do
    [
      c.contract_id,
      c.buyer,
      Integer.to_string(c.quantity),
      Integer.to_string(c.max_group_unit_minor),
      Integer.to_string(c.expires_at),
      c.evidence_ref
    ]
  end

  defp digest(fields) do
    serialized = Enum.map_join(fields, "", fn field -> "#{byte_size(field)}:#{field}" end)
    :crypto.hash(:sha256, serialized) |> Base.encode16(case: :lower)
  end

  defp identifier(v) when is_binary(v) and byte_size(v) in 1..256,
    do: if(String.trim(v) != "", do: :ok, else: {:error, :invalid_identifier})

  defp identifier(_), do: {:error, :invalid_identifier}
  defp evidence(v), do: identifier(v)
  defp positive(v), do: is_integer(v) and v > 0 and v <= @max

  defp public_id?(value) when is_binary(value) do
    case URI.parse(value) do
      %URI{scheme: "https", host: host, userinfo: nil, query: nil, fragment: nil}
      when is_binary(host) ->
        String.contains?(host, ".") and not String.contains?(host, "..")

      _ ->
        false
    end
  end

  defp public_id?(_), do: false
end
