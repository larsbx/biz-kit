defmodule SalesCore.Campaign do
  @moduledoc """
  Plan *candidate* promotional recipients from recorded, scoped consent.

  Produces no notification or account record. Consent must be rechecked
  against an authoritative, up-to-date state immediately before actual send.
  """

  alias SalesCore.Consent

  def plan(state, tenant, channel, jurisdiction, audience) when is_list(audience) do
    if Map.get(state, :tenant) == tenant do
      selected =
        audience
        |> Enum.filter(fn
          %{party_ref: ref, audience: kind} ->
            Consent.allowed?(state, tenant, ref, channel, jurisdiction, kind)

          _ ->
            false
        end)
        |> Enum.map(& &1.party_ref)
        |> Enum.uniq()
        |> Enum.sort()

      {:ok, %{consent_version: state.version, recipient_refs: selected}}
    else
      {:error, :wrong_tenant}
    end
  end

  def plan(_, _, _, _, _), do: {:error, :invalid_campaign_audience}
end
