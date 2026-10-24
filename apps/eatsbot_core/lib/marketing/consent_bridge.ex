defmodule EatsbotCore.Marketing.ConsentBridge do
  @moduledoc """
  Fail-closed adapter for Eatsbot's existing Telegram subscribers.

  Imported `:subscribed` rows do not alone provide a portable, verifiable
  cross-domain consent receipt. Original Eatsbot unsubscribe behavior stays
  authoritative until explicit, audited consent import is implemented.
  """

  def eligibility(%{status: :unsubscribed}), do: {:ok, :suppressed}
  def eligibility(%{status: :subscribed}), do: {:error, :consent_provenance_required}
  def eligibility(_), do: {:error, :unknown_subscription_status}
end
