defmodule BarterCore.ConsumerExchange do
  @moduledoc """
  Pure, **non-authoritative** admission preview for two consumer market routes:

  * `:direct_p2p`: an adult individual proposes an in-kind exchange with
    another adult individual, without a business intermediary.
  * `:business_consignment`: an adult individual proposes to supply a
    specific item through a verified business and its scoped agent to an
    individual or business recipient.

  This is separate from the business-only brokerage and commercial clearing
  domains. No personal participant gains commercial ledger, Hawala, custody,
  transferable credit, payout or cross-border payment authority.

  All status, identity and consent fields here are caller assertions. The
  authoritative host must independently validate identities, age eligibility,
  registrations, agency grants, signatures, actual inventory/title, risk and
  regulatory policy at **every** write boundary. Even a positive preview is
  never a permission to reserve stock, publish, deliver, or settle.
  """

  alias BarterCore, as: B

  @schema "bizkit.consumer-exchange.preview.v1"
  @trade_keys ~w(mode seller buyer broker offer_ref offer_revision want_ref want_revision consideration expires_at)a
  @person_keys ~w(kind principal_id verification age_status country expires_at)a
  @business_keys ~w(kind business_id verification country expires_at)a
  @broker_keys ~w(business agent seller_consent_ref seller_consent_revision terms_hash expires_at)a
  @agent_keys ~w(principal_id business_id grant_ref grant_revision grant_state scopes expires_at)a
  @consignment_scope :consignment_intermediation

  @doc """
  Preflight an exact, in-kind exchange snapshot. Does not verify any host claims.

  Both flows return `:requires_independent_host_admission` domestically.
  Any crossing of jurisdiction/country boundaries returns
  `:held_for_cross_border_classification` instead. This is only a modeled
  HOLD; nothing is authorized in either case.
  """
  def preview(trade, now) when is_map(trade) and is_integer(now) and now >= 0 do
    with :ok <- valid_trade(trade, now),
         :ok <- valid_participants(trade, now),
         :ok <- valid_intermediary(trade, now) do
      country_scope = country_scope(trade)

      {:ok,
       %{
         schema: @schema,
         mode: trade.mode,
         snapshot_digest: digest(trade),
         country_scope: country_scope,
         decision:
           if(country_scope == :domestic_candidate,
             do: :requires_independent_host_admission,
             else: :held_for_cross_border_classification
           ),
         status: :unadmitted_preview_only,
         evidence: :caller_asserted_unverified,
         title_transfer: false,
         inventory_reserved: false,
         legal_consent_verified: false,
         consumer_credit_issued: false,
         payment_or_value_transfer: false,
         business_clearing_authority: false,
         expires_at: trade.expires_at
       }}
    end
  end

  def preview(_, _), do: {:error, :invalid_trade}

  defp valid_trade(t, now) do
    valid =
      exact_keys?(t, @trade_keys) and
        t.mode in [:direct_p2p, :business_consignment] and
        t.consideration == :specified_in_kind_exchange and
        valid_ref?(t.offer_ref) and
        positive_revision?(t.offer_revision) and
        valid_ref?(t.want_ref) and
        positive_revision?(t.want_revision) and
        t.offer_ref != t.want_ref and
        is_integer(t.expires_at) and
        t.expires_at > now

    if valid, do: :ok, else: {:error, :invalid_trade}
  end

  defp valid_participants(t, now) do
    seller_ok = valid_person?(t.seller, now)

    buyer_ok =
      case t.mode do
        :direct_p2p -> valid_person?(t.buyer, now)
        :business_consignment -> valid_person?(t.buyer, now) or valid_business?(t.buyer, now)
      end

    distinct =
      if is_map(t.seller) and is_map(t.buyer) do
        participant_id(t.seller) != participant_id(t.buyer)
      else
        false
      end

    if seller_ok and buyer_ok and distinct, do: :ok, else: {:error, :ineligible_counterparty}
  end

  defp valid_intermediary(%{mode: :direct_p2p, broker: nil}, _now), do: :ok

  defp valid_intermediary(%{mode: :business_consignment, broker: %{} = b}, now) do
    valid =
      exact_keys?(b, @broker_keys) and
        valid_business?(b.business, now) and
        valid_agent?(b.agent, b.business, now) and
        valid_ref?(b.seller_consent_ref) and
        positive_revision?(b.seller_consent_revision) and
        is_binary(b.terms_hash) and
        String.match?(b.terms_hash, ~r/\A[0-9a-f]{64}\z/) and
        is_integer(b.expires_at) and
        b.expires_at > now

    if valid, do: :ok, else: {:error, :unverified_intermediary}
  end

  defp valid_intermediary(_, _), do: {:error, :invalid_intermediation}

  defp valid_agent?(a, b, now) when is_map(a) and is_map(b) do
    exact_keys?(a, @agent_keys) and
      valid_principal?(a.principal_id) and
      a.business_id == b.business_id and
      valid_ref?(a.grant_ref) and
      positive_revision?(a.grant_revision) and
      a.grant_state == :active and
      is_list(a.scopes) and
      a.scopes == [@consignment_scope] and
      is_integer(a.expires_at) and
      a.expires_at > now
  end

  defp valid_agent?(_, _, _), do: false

  defp valid_person?(p, now) when is_map(p) do
    exact_keys?(p, @person_keys) and
      p.kind == :individual and
      valid_principal?(p.principal_id) and
      p.verification == :current and
      p.age_status == :adult and
      valid_country?(p.country) and
      is_integer(p.expires_at) and p.expires_at > now
  end

  defp valid_person?(_, _), do: false

  defp valid_business?(b, now) when is_map(b) do
    exact_keys?(b, @business_keys) and
      b.kind == :business and
      valid_ref?(b.business_id) and
      b.verification == :current and
      valid_country?(b.country) and
      is_integer(b.expires_at) and b.expires_at > now
  end

  defp valid_business?(_, _), do: false

  defp country_scope(t) do
    countries =
      [t.seller.country, t.buyer.country] ++
        if(t.mode == :business_consignment, do: [t.broker.business.country], else: [])

    if length(Enum.uniq(countries)) == 1, do: :domestic_candidate, else: :cross_border
  end

  defp digest(t) do
    B.digest(
      [
        @schema,
        Atom.to_string(t.mode),
        t.offer_ref,
        Integer.to_string(t.offer_revision),
        t.want_ref,
        Integer.to_string(t.want_revision),
        Atom.to_string(t.consideration),
        Integer.to_string(t.expires_at)
      ] ++ participant_fields(t.seller) ++ participant_fields(t.buyer) ++ broker_fields(t.broker)
    )
  end

  defp participant_fields(%{kind: :individual} = p) do
    [
      Atom.to_string(p.kind),
      p.principal_id,
      Atom.to_string(p.verification),
      Atom.to_string(p.age_status),
      p.country,
      Integer.to_string(p.expires_at)
    ]
  end

  defp participant_fields(%{kind: :business} = b) do
    [
      Atom.to_string(b.kind),
      b.business_id,
      Atom.to_string(b.verification),
      b.country,
      Integer.to_string(b.expires_at)
    ]
  end

  defp broker_fields(nil), do: ["no_broker"]

  defp broker_fields(b) do
    participant_fields(b.business) ++
      [
        b.agent.principal_id,
        b.agent.business_id,
        b.agent.grant_ref,
        Integer.to_string(b.agent.grant_revision),
        Atom.to_string(b.agent.grant_state),
        Atom.to_string(@consignment_scope),
        Integer.to_string(b.agent.expires_at),
        b.seller_consent_ref,
        Integer.to_string(b.seller_consent_revision),
        b.terms_hash,
        Integer.to_string(b.expires_at)
      ]
  end

  defp participant_id(%{kind: :individual, principal_id: id}), do: id
  defp participant_id(%{kind: :business, business_id: id}), do: id
  defp participant_id(_), do: nil

  defp valid_principal?(id),
    do: is_binary(id) and String.match?(id, ~r/\Aprn_[a-z2-7]{26}\z/)

  defp valid_ref?(id), do: B.valid_public_id?(id)
  defp valid_country?(value), do: is_binary(value) and String.match?(value, ~r/\A[A-Z]{2}\z/)
  defp positive_revision?(value), do: is_integer(value) and value > 0
  defp exact_keys?(map, keys), do: Enum.sort(Map.keys(map)) == Enum.sort(keys)
end
