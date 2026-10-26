defmodule BarterCore.Brokerage do
  @moduledoc """
  Contractual preview for a temporary, participant-governed brokerage
  vehicle. Every matched participant joins through the same explicit
  agreement, which delegates only matching/reconciliation.

  This module does NOT incorporate/register a company, grant it agency,
  validate signatures, transfer title, hold property, post journal entries,
  or assert cross-node atomic consensus. Independent legal formation,
  authority checks and local ledger admission are separate requirements.
  """

  alias BarterCore, as: B

  @schema "bizkit.barter.brokerage-agreement.v1"
  @charter_keys ~w(company_id charter_hash version expires_at authority title_policy formation)a
  @consent_keys ~w(actor agreement_hash evidence_ref)a

  @doc """
  Bind a verified exact optimal clearing plan to a temporary brokerage
  charter and generate immutable participant-wide contract terms.
  """
  def draft(plan, charter, now) when is_integer(now) and now >= 0 do
    with {:ok, ^plan} <- B.verify_plan(plan, now),
         :ok <- valid_charter(charter, now),
         true <- plan.matched_intents >= 2 do
      members =
        plan.cycles
        |> Enum.flat_map(& &1.participants)
        |> Enum.uniq()
        |> Enum.sort()

      expires_at =
        min(charter.expires_at, Enum.min(Enum.map(plan.cycles, & &1.valid_until)))

      fields = [
        @schema,
        plan.terms_hash,
        charter.company_id,
        charter.charter_hash,
        Integer.to_string(charter.version),
        Integer.to_string(charter.expires_at),
        Atom.to_string(charter.authority),
        Atom.to_string(charter.title_policy),
        Atom.to_string(charter.formation),
        Integer.to_string(length(members))
      ] ++ members

      {:ok,
       %{
         schema: @schema,
         plan: plan,
         charter: charter,
         members: members,
         expires_at: expires_at,
         agreement_hash: B.digest(fields),
         status: :draft_requires_participant_contract_and_legal_formation
       }}
    else
      _ -> {:error, :invalid_brokerage_draft}
    end
  end

  def draft(_, _, _), do: {:error, :invalid_brokerage_draft}

  @doc """
  Check the shape, actor coverage and exact digest of supplied consent refs.
  Signature checks and proof of member/company formation are host duties.
  The result is a *preview only* with direct-provider contingent obligations.
  """
  def pre_delivery_preview(%{plan: plan, charter: charter} = agreement, consents, now)
      when is_list(consents) and is_integer(now) and now >= 0 do
    with {:ok, ^agreement} <- draft(plan, charter, now),
         :ok <- check_consents(agreement, consents) do
      legs =
        Enum.flat_map(agreement.plan.cycles, fn cycle ->
          Enum.map(cycle.legs, fn leg ->
            %{
              kind: :conditional_in_kind_delivery,
              brokerage_id: agreement.charter.company_id,
              provider: leg.from,
              recipient: leg.to,
              asset: leg.asset,
              provider_intent: leg.from_intent,
              recipient_intent: leg.to_intent,
              status: :not_admitted
            }
          end)
        end)

      {:ok,
       %{
         agreement_hash: agreement.agreement_hash,
         brokerage_id: agreement.charter.company_id,
         participants: agreement.members,
         membership_evidence_refs: Enum.map(consents, & &1.evidence_ref),
         expires_at: agreement.expires_at,
         vehicle_status: :unformed_pending_external_legal_confirmation,
         status: :requires_independent_authorized_local_admission,
         obligations: legs,
         company_takes_title: false
       }}
    else
      _ -> {:error, :invalid_brokerage_consents}
    end
  end

  def pre_delivery_preview(_, _, _), do: {:error, :invalid_brokerage_consents}

  defp check_consents(agreement, consents) do
    actors = Enum.map(consents, fn c -> if is_map(c), do: Map.get(c, :actor), else: nil end)

    refs =
      Enum.map(consents, fn c ->
        if is_map(c), do: Map.get(c, :evidence_ref), else: nil
      end)

    acceptable =
      length(consents) == length(agreement.members) and
        Enum.sort(actors) == agreement.members and
        length(Enum.uniq(refs)) == length(refs) and
        Enum.all?(consents, fn c ->
          is_map(c) and
            Enum.sort(Map.keys(c)) == Enum.sort(@consent_keys) and
            c.agreement_hash == agreement.agreement_hash and
            is_binary(c.evidence_ref) and
            byte_size(c.evidence_ref) in 1..256 and
            String.trim(c.evidence_ref) != ""
        end)

    if acceptable, do: :ok, else: {:error, :invalid_consents}
  end

  defp valid_charter(charter, now) when is_map(charter) do
    valid =
      Enum.sort(Map.keys(charter)) == Enum.sort(@charter_keys) and
        B.valid_public_id?(charter.company_id) and
        is_binary(charter.charter_hash) and
        String.match?(charter.charter_hash, ~r/\A[0-9a-f]{64}\z/) and
        is_integer(charter.version) and charter.version > 0 and
        is_integer(charter.expires_at) and charter.expires_at > now and
        charter.authority == :matching_and_reconciliation_only and
        charter.title_policy == :retained_by_providers and
        charter.formation == :requires_external_legal_confirmation

    if valid, do: :ok, else: {:error, :invalid_charter}
  end

  defp valid_charter(_, _), do: {:error, :invalid_charter}
end
