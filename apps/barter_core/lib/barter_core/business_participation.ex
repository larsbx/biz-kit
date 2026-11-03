defmodule BarterCore.BusinessParticipation do
  @moduledoc """
  Pure, inert preflight for the **business-only** reciprocal trade marketplace.

  Legal business entities are the only counterparties and members. Humans or
  service principals may act solely under a current, entity-bound, operation-
  scoped agency grant. A principal is never promoted into a personal member.

  Inputs are *host assertions*, not verified registration, sanctions, identity
  or agency evidence. Success never authorizes a command, ledger admission,
  transferable credit, payment, delivery or cross-border value transfer.
  The authoritative host must independently verify the current registry,
  grant, authenticated signer and jurisdiction policy at the write boundary.
  """

  alias BarterCore, as: B

  @schema "bizkit.barter.business-participation-preflight.v1"
  @business_keys ~w(business_id business_kind registration_ref registration_revision registration_valid_until registration_state sanctions_state)a
  @agent_keys ~w(principal_id business_id grant_ref grant_revision grant_state scopes expires_at)a
  @business_kinds [:registered_company, :registered_cooperative, :registered_partnership, :registered_sole_proprietorship]
  @trade_scopes [:publish_supply, :publish_need, :negotiate_trade, :approve_trade, :approve_clearing, :confirm_fulfillment]
  @cross_border_scopes [:cross_border_reciprocal_fulfillment]
  @financial_scopes [:issue_transferable_credit, :send_money, :cash_payout, :instruct_third_party_value_transfer]
  @all_scopes @trade_scopes ++ @cross_border_scopes

  @doc """
  Validate the shape of a host-supplied business and agency snapshot.

  A successful result is **not** authoritative. The cross-border fulfillment
  scope remains held for an independent jurisdiction/activity classification.
  The legacy public marketplace and clearing functions are not rewired by
  this pure module; it must be integrated at every host admission boundary.
  """
  def preflight(business, agent, scope, now)
      when is_integer(now) and now >= 0 do
    cond do
      scope in @financial_scopes ->
        {:error, :financial_capability_not_supported}

      scope not in @all_scopes ->
        {:error, :unsupported_scope}

      true ->
        with :ok <- validate_business(business, now),
             :ok <- validate_agent(agent, business, scope, now) do
          {:ok,
           %{
             schema: @schema,
             business_id: business.business_id,
             principal_id: agent.principal_id,
             requested_scope: scope,
             registration_ref: business.registration_ref,
             registration_revision: business.registration_revision,
             grant_ref: agent.grant_ref,
             grant_revision: agent.grant_revision,
             expires_at: min(business.registration_valid_until, agent.expires_at),
             state: preflight_state(scope),
             evidence: :unverified_host_assertions,
             local_admission: :forbidden_until_authoritative_verification,
             personal_membership: false,
             financial_authority: false
           }}
        end
    end
  end

  def preflight(_, _, _, _), do: {:error, :invalid_preflight_request}

  defp validate_business(%{} = b, now) do
    valid =
      exact_keys?(b, @business_keys) and
        B.valid_public_id?(b.business_id) and
        b.business_kind in @business_kinds and
        B.valid_public_id?(b.registration_ref) and
        positive_revision?(b.registration_revision) and
        is_integer(b.registration_valid_until) and
        b.registration_valid_until > now and
        b.registration_state == :current and
        b.sanctions_state == :clear

    if valid, do: :ok, else: {:error, :business_not_eligible}
  end

  defp validate_business(_, _), do: {:error, :business_not_eligible}

  defp validate_agent(%{} = a, b, scope, now) do
    valid =
      exact_keys?(a, @agent_keys) and
        valid_principal?(a.principal_id) and
        a.business_id == b.business_id and
        B.valid_public_id?(a.grant_ref) and
        positive_revision?(a.grant_revision) and
        a.grant_state == :active and
        is_integer(a.expires_at) and
        a.expires_at > now and
        is_list(a.scopes) and
        a.scopes != [] and
        Enum.uniq(a.scopes) == a.scopes and
        Enum.all?(a.scopes, &(&1 in @all_scopes)) and
        scope in a.scopes

    if valid, do: :ok, else: {:error, :agent_not_authorized}
  end

  defp validate_agent(_, _, _, _), do: {:error, :agent_not_authorized}

  defp preflight_state(:cross_border_reciprocal_fulfillment),
    do: :held_for_independent_cross_border_classification

  defp preflight_state(_), do: :host_authority_verification_required

  defp exact_keys?(map, keys), do: Enum.sort(Map.keys(map)) == Enum.sort(keys)
  defp positive_revision?(value), do: is_integer(value) and value > 0

  # Mirrors the public principal-ID shape, not an identity lookup or grant check.
  defp valid_principal?(id),
    do: is_binary(id) and String.match?(id, ~r/\Aprn_[a-z2-7]{26}\z/)
end
