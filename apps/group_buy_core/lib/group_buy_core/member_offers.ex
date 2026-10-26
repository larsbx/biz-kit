defmodule GroupBuyCore.MemberOffers do
  @moduledoc """
  Members-only distribution contract for seller-authored monetary cash prices,
  volume tier rates and deadlines.

  This is a PRIVATE projection adapter, not an authentication or publication
  server. The caller must be the trusted seller-home host, with membership,
  seller signature and disclosure authority independently verified. Never
  send the complete result as ActivityPub Public or iroh public gossip.
  """

  alias GroupBuyCore, as: Group

  @schema "bizkit.group-buy.members-only-offer.v1"
  @context_keys ~w(authenticated_seller recipient membership_evidence_ref
                   authorization audience)a

  @doc """
  Provide exact member-only terms only to a host-authorized recipient.
  Independent purchasers still retain the monetary solo-price option.
  """
  def private_offer(offer, context, now) when is_map(context) do
    with {:ok, _} <- Group.quote(offer, [], now),
         :ok <- check_context(offer, context) do
      {:ok,
       %{
         schema: @schema,
         audience: :members_only,
         recipient: context.recipient,
         membership_evidence_ref: context.membership_evidence_ref,
         seller: offer.seller,
         offer: offer,
         cash_checkout: :available_independently,
         group_discount: :conditional_on_host_admitted_contracted_volume,
         transport: :requires_private_authenticated_delivery
       }}
    end
  end

  def private_offer(_, _, _), do: {:error, :unauthorized_member_offer}

  @doc """
  No public rate/price projection is emitted. Member-only market discovery
  should use authorized, purpose-limited private channels instead of exposing
  offers, prices or recipients through a public listing/gossip transport.
  """
  def public_projection(_offer), do: {:error, :members_only_no_public_projection}

  defp check_context(offer, context) do
    valid =
      Enum.sort(Map.keys(context)) == Enum.sort(@context_keys) and
        context.authenticated_seller == offer.seller and
        context.audience == :members_only and
        context.authorization == :host_verified_membership_and_disclosure and
        member_id?(context.recipient) and
        context.recipient != offer.seller and
        is_binary(context.membership_evidence_ref) and
        byte_size(context.membership_evidence_ref) in 1..256 and
        String.trim(context.membership_evidence_ref) != ""

    if valid, do: :ok, else: {:error, :unauthorized_member_offer}
  end

  defp member_id?(value) when is_binary(value) and byte_size(value) <= 2048 do
    case URI.parse(value) do
      %URI{scheme: "https", host: host, path: path, userinfo: nil,
           query: nil, fragment: nil}
      when is_binary(host) and is_binary(path) and path != "" ->
        String.contains?(host, ".") and not String.contains?(host, "..")

      _ ->
        false
    end
  end

  defp member_id?(_), do: false
end
