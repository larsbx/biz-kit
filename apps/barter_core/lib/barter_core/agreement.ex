defmodule BarterCore.Agreement do
  @moduledoc """
  A pure pre-delivery accounting *preview*, not an agreement executor.

  The host must authenticate and authorize every consent evidence reference,
  bind the participant's signature to the exact route digest, recheck expiry
  and current inventory versions, and independently admit an obligation into
  each participant's signed local ledger. This module cannot verify a URL,
  a signature, an external escrow or another node's ledger.
  """

  alias BarterCore

  @consent_keys ~w(actor terms_hash evidence_ref)a

  @doc """
  Render conditional bilateral obligations once exactly one purported
  consent reference for every participant matches the immutable route.

  This is only a candidate for local verification/admission. No delivery,
  inventory hold, payment, compensation or settlement is posted here.
  """
  def pre_delivery_preview(route, consents, now) when is_list(consents) do
    with {:ok, route} <- BarterCore.verify_route(route, now),
         :ok <- check_consents(route, consents) do
      {:ok,
       %{
         status: :requires_independent_local_admission,
         terms_hash: route.terms_hash,
         expires_at: route.valid_until,
         evidence_refs: Enum.map(consents, & &1.evidence_ref),
         entries:
           Enum.map(route.legs, fn leg ->
             %{
               kind: :conditional_barter_delivery,
               provider: leg.from,
               recipient: leg.to,
               provided_asset: leg.asset,
               provider_intent: leg.from_intent,
               recipient_intent: leg.to_intent,
               state: :not_admitted
             }
           end)
       }}
    end
  end

  def pre_delivery_preview(_, _, _), do: {:error, :invalid_consents}

  defp check_consents(route, consents) do
    actors =
      Enum.map(consents, fn consent ->
        if is_map(consent), do: Map.get(consent, :actor), else: nil
      end)

    valid? =
      length(consents) == length(route.participants) and
        Enum.all?(consents, fn consent ->
          is_map(consent) and
            Enum.sort(Map.keys(consent)) == Enum.sort(@consent_keys) and
            consent.terms_hash == route.terms_hash and
            is_binary(consent.evidence_ref) and
            byte_size(consent.evidence_ref) in 1..256 and
            String.trim(consent.evidence_ref) != ""
        end) and
        Enum.sort(actors) == Enum.sort(route.participants)

    if valid?, do: :ok, else: {:error, :invalid_consents}
  end
end
