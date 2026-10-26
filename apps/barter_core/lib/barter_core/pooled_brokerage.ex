defmodule BarterCore.PooledBrokerage do
  @moduledoc """
  A member-governed temporary brokerage *contract draft* for a pooled
  in-kind clearing plan. No legal entity is created by this function, no
  signatures are verified, and no binding stock or ledger action occurs.
  """

  alias BarterCore, as: B
  alias BarterCore.PooledClearing

  @schema "bizkit.barter.pooled-brokerage-contract.v1"
  @charter_keys ~w(company_id charter_hash version expires_at authority title_policy formation)a
  @consent_keys ~w(actor agreement_hash evidence_ref)a

  @doc "Bind a full independently optimized market snapshot to member terms."
  def draft(plan, charter, now, opts \\ [])

  def draft(plan, charter, now, opts) when is_integer(now) and now >= 0 do
    with {:ok, ^plan} <- PooledClearing.verify_plan(plan, now, opts),
         :ok <- valid_charter(charter, now),
         true <- plan.participants != [] do
      last_snapshot_expiry =
        plan.snapshot
        |> Enum.filter(&Enum.member?(plan.participants, &1.actor))
        |> Enum.map(& &1.valid_until)
        |> Enum.min()

      expires_at = min(last_snapshot_expiry, charter.expires_at)

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
        Integer.to_string(length(plan.participants))
      ] ++ plan.participants

      {:ok,
       %{
         schema: @schema,
         plan: plan,
         charter: charter,
         members: plan.participants,
         agreement_hash: B.digest(fields),
         expires_at: expires_at,
         status: :draft_pending_lawful_formation_and_mutual_contract
       }}
    else
      _ -> {:error, :invalid_brokerage_draft}
    end
  end

  def draft(_, _, _, _), do: {:error, :invalid_brokerage_draft}

  @doc """
  Provide an explicit audit preview of proposed supplier-to-recipient legs.
  Every member's evidence ref must be bound to identical full charter+terms,
  but these are **unverified** proof references, not signature validation.

  This is not an approved exchange, a balanced valuation statement, a
  company authorization, an accounting transaction or a delivery record.
  """
  def pre_delivery_preview(draft, consents, now, opts \\ [])

  def pre_delivery_preview(%{plan: plan, charter: charter} = agreement, consents, now, opts)
      when is_list(consents) and is_integer(now) and now >= 0 do
    with {:ok, ^agreement} <- draft(plan, charter, now, opts),
         :ok <- validate_consents(agreement, consents) do
      obligations =
        Enum.map(agreement.plan.transfers, fn transfer ->
          %{
            kind: :conditional_in_kind_transfer,
            from: transfer.from,
            to: transfer.to,
            asset: transfer.asset,
            brokerage_id: charter.company_id,
            state: :not_admitted
          }
        end)

      {:ok,
       %{
         agreement_hash: agreement.agreement_hash,
         proposed_brokerage: charter.company_id,
         members: agreement.members,
         evidence_refs: Enum.map(consents, & &1.evidence_ref),
         obligations: obligations,
         unmet_needs: agreement.plan.unmatched_needs,
         unallocated_supplies: agreement.plan.unallocated_supplies,
         expiry: agreement.expires_at,
         status: :requires_signatures_legal_formation_and_local_admission,
         balancing: :requires_negotiated_consideration_and_member_approval,
         vehicle_formed: false,
         company_takes_title: false
       }}
    else
      _ -> {:error, :invalid_brokerage_consents}
    end
  end

  def pre_delivery_preview(_, _, _, _), do: {:error, :invalid_brokerage_consents}

  defp validate_consents(agreement, consents) do
    actors = Enum.map(consents, fn c -> if is_map(c), do: Map.get(c, :actor), else: nil end)
    refs = Enum.map(consents, fn c -> if is_map(c), do: Map.get(c, :evidence_ref), else: nil end)

    exact =
      Enum.sort(actors) == agreement.members and
        length(consents) == length(agreement.members) and
        length(Enum.uniq(refs)) == length(refs) and
        Enum.all?(consents, fn c ->
          is_map(c) and
            Enum.sort(Map.keys(c)) == Enum.sort(@consent_keys) and
            c.agreement_hash == agreement.agreement_hash and
            is_binary(c.evidence_ref) and
            byte_size(c.evidence_ref) in 1..256 and
            String.trim(c.evidence_ref) != ""
        end)

    if exact, do: :ok, else: {:error, :invalid_consents}
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
