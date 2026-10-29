defmodule GroupBuyCore.Escrow do
  @moduledoc """
  Exact, pure evidence ledger for **third-party-held** group-buy funds.

  Buyers arrange protected funds with an independently authorized escrow or
  payment provider. biz-kit NEVER becomes custodian and never treats a
  payment authorization, Iroh message, URL, or self-declared receipt as
  proof that funds are held.

  Trusted hosts MUST verify provider attestations externally, authenticate
  member/seller authority, and durably append source-owned events before
  calling this pure reducer. All provider actions represented here are
  observations of already verified external facts, not requests or transfers.
  """

  alias GroupBuyCore
  alias GroupBuyCore.BindingRound

  @schema "bizkit.group-buy.external-escrow.v1"
  @max 9_007_199_254_740_991
  @hold_keys ~w(id expected_version op buyer pledge_id provider_id custody_ref
                currency amount_minor expires_at evidence_ref)a
  @reconfirm_keys @hold_keys ++ [:prior_funding_evidence_ref]
  @dispute_keys ~w(id expected_version op buyer reason_ref)a
  @release_keys ~w(id expected_version op buyer provider_id custody_ref
                   settlement_ref delivery_proof_ref seller_paid_minor
                   buyer_refund_minor evidence_ref)a
  @refund_keys ~w(id expected_version op buyer provider_id custody_ref
                  refund_ref refund_minor reason resolution_ref evidence_ref)a

  @doc "Create a pure external-provider evidence projection for a seller campaign."
  def new(offer, now) do
    case GroupBuyCore.quote(offer, [], now) do
      {:ok, _} ->
        {:ok,
         %{
           schema: @schema,
           offer: offer,
           version: 0,
           positions: %{},
           seen: %{}
         }}

      error ->
        error
    end
  end

  @doc """
  Replay an authenticated event. Only provider-confirmed funding counts.

  Supported operations:
  - :hold_confirmed — a **verified external custodian** confirms segregated
    funds earmarked to a pledged buyer/quantity/campaign.
  - :hold_reconfirmed — a fresh provider observation renews the evidence
    for the SAME held allocation, explicitly superseding its prior evidence.
    Cannot change money, buyer, pledge, provider or custody identity, and
    cannot reopen released/refunded/disputed positions.
  - :delivery_release_confirmed — AFTER binding and verified delivery,
    provider confirms payment to seller AND refund of any surplus caused
    by a deeper discounted tier.
  - :refund_confirmed — full provider-confirmed refund if threshold fails
    by campaign expiry, or after independently verified lawful resolution.
  - :dispute_open — blocks ordinary release until a lawful refund/resolution
    event is externally authorized and confirmed.
  """
  def apply(state, round, actor, %{id: id, expected_version: expected, op: _} = cmd, now)
      when is_integer(now) and now >= 0 do
    with :ok <- state_scope(state, round),
         :ok <- identifier(id),
         :ok <- shape(cmd) do
      case Map.get(state.seen, id) do
        {^actor, ^cmd} ->
          {:ok, state, :duplicate}

        nil ->
          with :ok <- version(state.version, expected),
               {:ok, updated} <- transition(state, round, actor, cmd, now) do
            {:ok,
             %{
               updated
               | version: state.version + 1,
                 seen: Map.put(state.seen, id, {actor, cmd})
             }, :accepted}
          end

        _ ->
          {:error, :idempotency_conflict}
      end
    end
  end

  def apply(_, _, _, _, _), do: {:error, :invalid_escrow_event}

  @doc "Deterministically replay separately authenticated, host-admitted provider facts."
  def replay(state, round, steps) when is_list(steps) do
    Enum.reduce_while(steps, {:ok, state}, fn {actor, event, at}, {:ok, current} ->
      case apply(current, round, actor, event, at) do
        {:ok, next, _} -> {:cont, {:ok, next}}
        error -> {:halt, error}
      end
    end)
  end

  def replay(_, _, _), do: {:error, :invalid_escrow_replay}

  @doc """
  Verify that **all** automatically binding pledges are backed by current
  externally confirmed funds for their maximum first-tier group price.

  A missing/unverified hold MUST block seller-home activation acknowledgment,
  stock release and fulfillment. The BindingRound pure state alone is NOT
  sufficient for funding readiness. The seller home must atomically commit
  the accepted pledge/activation and evidence-of-funding fact in its local
  event ledger or refrain from claiming an escrow-secured group.
  """
  def coverage(state, round, now) when is_integer(now) and now >= 0 do
    with :ok <- state_scope(state, round),
         {:ok, %{status: :binding_threshold_activated} = bound} <-
           BindingRound.snapshot(round, now),
         :ok <- all_covered(state, round, now) do
      {:ok,
       %{
         campaign_id: state.offer.id,
         binding_terms_hash: bound.terms_hash,
         provider_funding: :externally_confirmed_by_trusted_host_only,
         buyers: length(bound.members),
         committed_units: bound.contracted_quantity,
         currency: bound.currency,
         secured_minor:
           Enum.sum(
             Enum.map(bound.members, fn member ->
               Map.fetch!(state.positions, member.buyer).amount_minor
             end)
           ),
         current_group_due_minor: bound.total_due_minor,
         seller_release: :blocked_until_verified_delivery_and_provider_confirmation,
         custody: :external_provider_not_biz_kit
       }}
    else
      {:ok, _} -> {:error, :threshold_not_activated}
      {:error, _} = error -> error
      _ -> {:error, :escrow_not_ready}
    end
  end

  def coverage(_, _, _), do: {:error, :invalid_escrow_coverage}

  @doc """
  Preview exact seller release and buyer surplus refund after a
  binding round. This does NOT instruct the custodian or authorize payout.
  """
  def settlement_preview(state, round, buyer, now) when is_binary(buyer) do
    with {:ok, cover} <- coverage(state, round, now),
         {:ok, bound} <- BindingRound.snapshot(round, now),
         member when not is_nil(member) <- Enum.find(bound.members, &(&1.buyer == buyer)),
         position when not is_nil(position) <- Map.get(state.positions, buyer) do
      {:ok,
       %{
         binding_terms_hash: cover.binding_terms_hash,
         buyer: buyer,
         pledge_id: member.pledge_id,
         currency: bound.currency,
         custody_ref: position.custody_ref,
         seller_due_minor: member.due_minor,
         buyer_surplus_refund_minor: position.amount_minor - member.due_minor,
         status: :requires_verified_delivery_and_external_provider_release,
         company_custody: false
       }}
    else
      nil -> {:error, :unknown_buyer}
      {:error, _} = error -> error
    end
  end

  def settlement_preview(_, _, _, _), do: {:error, :invalid_settlement_preview}

  defp transition(state, round, actor, %{op: :hold_confirmed} = c, now) do
    with true <- actor == {:custody_provider, c.provider_id},
         :ok <- identifier(c.provider_id),
         :ok <- reference(c.custody_ref),
         :ok <- reference(c.evidence_ref),
         :ok <- pledge_identity(round, c.buyer, c.pledge_id, now),
         :ok <- unique_custody_ref(state, c.custody_ref),
         true <- c.currency == state.offer.currency,
         true <- money?(c.amount_minor),
         true <-
           c.amount_minor ==
             pledge_quantity(round, c.buyer) * hd(state.offer.tiers).unit_minor,
         true <- is_integer(c.expires_at) and c.expires_at > state.offer.expires_at,
         false <- Map.has_key?(state.positions, c.buyer) do
      position = %{
        buyer: c.buyer,
        pledge_id: c.pledge_id,
        provider_id: c.provider_id,
        custody_ref: c.custody_ref,
        currency: c.currency,
        amount_minor: c.amount_minor,
        expires_at: c.expires_at,
        funding_evidence_ref: c.evidence_ref,
        status: :held,
        disposition: nil
      }

      {:ok, %{state | positions: Map.put(state.positions, c.buyer, position)}}
    else
      _ -> {:error, :invalid_or_duplicate_external_hold}
    end
  end

  defp transition(state, round, actor, %{op: :hold_reconfirmed} = c, now) do
    with {:ok, position} <- held(state, c.buyer),
         :ok <- provider_matches(actor, c, position),
         :ok <- pledge_identity(round, c.buyer, c.pledge_id, now),
         :ok <- reference(c.evidence_ref),
         true <- c.prior_funding_evidence_ref == position.funding_evidence_ref,
         true <- c.pledge_id == position.pledge_id and c.currency == position.currency,
         true <- c.amount_minor == position.amount_minor,
         true <- money?(c.amount_minor),
         true <- is_integer(c.expires_at) and c.expires_at <= @max,
         true <- c.expires_at > max(now, state.offer.expires_at),
         true <- c.expires_at >= position.expires_at do
      update_position(state, c.buyer, %{
        position
        | expires_at: c.expires_at,
          funding_evidence_ref: c.evidence_ref
      })
    else
      _ -> {:error, :reconfirmation_requires_same_held_allocation_and_prior_evidence}
    end
  end

  defp transition(state, round, actor, %{op: :delivery_release_confirmed} = c, now) do
    with {:ok, position} <- held(state, c.buyer),
         :ok <- provider_matches(actor, c, position),
         :ok <- reference(c.settlement_ref),
         :ok <- unique_disposition_ref(state, c.settlement_ref),
         :ok <- reference(c.delivery_proof_ref),
         :ok <- reference(c.evidence_ref),
         true <- now < position.expires_at,
         {:ok, _} <- coverage(state, round, now),
         {:ok, %{status: :binding_threshold_activated} = bound} <-
           BindingRound.snapshot(round, now),
         member when not is_nil(member) <- Enum.find(bound.members, &(&1.buyer == c.buyer)),
         true <- c.seller_paid_minor == member.due_minor,
         true <- c.buyer_refund_minor == position.amount_minor - member.due_minor,
         true <- money?(c.seller_paid_minor) and money?(c.buyer_refund_minor) do
      update_position(state, c.buyer, %{
        position
        | status: :released,
          disposition: %{
            seller_minor: c.seller_paid_minor,
            buyer_refund_minor: c.buyer_refund_minor,
            settlement_ref: c.settlement_ref,
            delivery_proof_ref: c.delivery_proof_ref,
            provider_evidence_ref: c.evidence_ref
          }
      })
    else
      _ -> {:error, :release_requires_binding_funding_and_verified_delivery}
    end
  end

  defp transition(state, round, actor, %{op: :refund_confirmed} = c, now) do
    with {:ok, position} <- held_or_disputed(state, c.buyer),
         :ok <- provider_matches(actor, c, position),
         :ok <- reference(c.refund_ref),
         :ok <- unique_disposition_ref(state, c.refund_ref),
         :ok <- reference(c.evidence_ref),
         true <- c.refund_minor == position.amount_minor,
         :ok <- refund_permitted(round, c, now) do
      update_position(state, c.buyer, %{
        position
        | status: :refunded,
          disposition: %{
            buyer_refund_minor: c.refund_minor,
            refund_ref: c.refund_ref,
            resolution_ref: c.resolution_ref,
            provider_evidence_ref: c.evidence_ref
          }
      })
    else
      _ -> {:error, :refund_requires_failed_threshold_or_lawful_resolution}
    end
  end

  defp transition(state, round, actor, %{op: :dispute_open} = c, _now) do
    with {:ok, position} <- held(state, c.buyer),
         true <- actor in [c.buyer, state.offer.seller],
         :ok <- reference(c.reason_ref),
         true <- Map.has_key?(round.pledges, c.buyer) do
      update_position(state, c.buyer, %{position | status: :disputed})
    else
      _ -> {:error, :invalid_dispute}
    end
  end

  defp transition(_, _, _, _, _), do: {:error, :invalid_escrow_event}

  defp refund_permitted(round, %{reason: :threshold_failed, resolution_ref: nil}, now) do
    if round.activated == nil and now >= round.offer.expires_at,
      do: :ok,
      else: {:error, :threshold_not_failed}
  end

  defp refund_permitted(_round, %{reason: :lawful_resolution, resolution_ref: ref}, _now),
    do: reference(ref)

  defp refund_permitted(_, _, _), do: {:error, :invalid_refund_reason}

  defp provider_matches(actor, c, position) do
    if actor == {:custody_provider, position.provider_id} and
         c.provider_id == position.provider_id and c.custody_ref == position.custody_ref,
       do: :ok,
       else: {:error, :wrong_provider_or_custody}
  end

  defp pledge_identity(round, buyer, pledge_id, now) do
    case Map.get(round.pledges, buyer) do
      %{id: ^pledge_id, expires_at: expires} ->
        if round.activated != nil or expires > now,
          do: :ok,
          else: {:error, :expired_pledge}

      _ ->
        {:error, :unknown_pledge}
    end
  end

  defp pledge_quantity(round, buyer), do: round.pledges[buyer].quantity

  defp all_covered(state, round, now) do
    if Enum.all?(round.pledges, fn {buyer, pledge} ->
         case Map.get(state.positions, buyer) do
           %{
             pledge_id: id,
             status: status,
             expires_at: expiry,
             amount_minor: value
           } ->
             id == pledge.id and status in [:held, :released] and
               (status == :released or expiry > now) and
               value >= pledge.quantity * hd(state.offer.tiers).unit_minor

           _ ->
             false
         end
       end) do
      :ok
    else
      {:error, :escrow_coverage_incomplete}
    end
  end

  defp held(state, buyer) do
    case Map.get(state.positions, buyer) do
      %{status: :held} = p -> {:ok, p}
      _ -> {:error, :not_held}
    end
  end

  defp held_or_disputed(state, buyer) do
    case Map.get(state.positions, buyer) do
      %{status: status} = p when status in [:held, :disputed] -> {:ok, p}
      _ -> {:error, :not_refundable}
    end
  end

  defp update_position(state, buyer, position),
    do: {:ok, %{state | positions: Map.put(state.positions, buyer, position)}}

  defp unique_custody_ref(state, custody_ref) do
    if Enum.any?(Map.values(state.positions), &(&1.custody_ref == custody_ref)),
      do: {:error, :reused_custody_ref},
      else: :ok
  end

  # Do not count a provider's payout/refund receipt for two buyers.
  # Global uniqueness across campaigns remains the provider's responsibility.
  defp unique_disposition_ref(state, reference_id) do
    reused =
      Enum.any?(Map.values(state.positions), fn position ->
        case position.disposition do
          %{} = disposition ->
            Map.get(disposition, :settlement_ref) == reference_id or
              Map.get(disposition, :refund_ref) == reference_id

          _ ->
            false
        end
      end)

    if reused, do: {:error, :reused_provider_receipt}, else: :ok
  end

  defp state_scope(
         %{schema: @schema, offer: offer, positions: positions, seen: seen, version: version},
         %{offer: other, pledges: pledges}
       )
       when offer == other and is_map(positions) and is_map(seen) and
              is_map(pledges) and is_integer(version) and version >= 0,
       do: :ok

  defp state_scope(_, _), do: {:error, :wrong_campaign_scope}

  defp shape(%{op: :hold_reconfirmed} = c), do: exact(c, @reconfirm_keys)
  defp shape(%{op: :hold_confirmed} = c), do: exact(c, @hold_keys)
  defp shape(%{op: :delivery_release_confirmed} = c), do: exact(c, @release_keys)
  defp shape(%{op: :refund_confirmed} = c), do: exact(c, @refund_keys)
  defp shape(%{op: :dispute_open} = c), do: exact(c, @dispute_keys)
  defp shape(_), do: {:error, :invalid_escrow_event}

  defp exact(c, keys) do
    if Enum.sort(Map.keys(c)) == Enum.sort(keys),
      do: :ok,
      else: {:error, :invalid_escrow_event}
  end

  defp version(a, a), do: :ok
  defp version(_, _), do: {:error, :stale_escrow_version}

  defp money?(value), do: is_integer(value) and value >= 0 and value <= @max

  defp identifier(value) when is_binary(value) and byte_size(value) in 1..256,
    do: if(String.trim(value) != "", do: :ok, else: {:error, :invalid_identifier})

  defp identifier(_), do: {:error, :invalid_identifier}
  defp reference(value), do: identifier(value)
end
