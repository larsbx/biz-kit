defmodule CoopSubstrate.CommercialSourceLineage do
  @moduledoc """
  Business-log read projection of source-claim SIGNED-CORE provenance.

  A SHA-256 digest of `Envelope.signing_bytes/1` binds the canonical source
  event core to the parties' signatures; it is NOT the full log-assigned
  `Envelope.event_hash/1` and does not claim independent invoice validity.

  The existing single canonical CoopSubstrate.Log remains the business
  authority. This projection is NOT a writer, source reservation, signed
  clearance, transfer of money, or proof of corporate agency/legal release.

  A source that has ever been assigned remains ineligible for the narrow
  original-only source proof, even if it returns to its first debtor.
  Legacy netting residuals also remain ineligible without an independently
  verified source-lineage mechanism.
  """

  alias CoopSubstrate.Protocol.Envelope

  @doc "Record original attested source core (not the final event-record hash)."
  def recorded(%Envelope{type: "ObligationRecorded", chapter_id: ch, payload: p} = env, state) do
    digest = signed_core_digest(env)

    source = %{
      original_signed_core_digest: digest,
      latest_signed_core_digest: digest,
      source_revision: 1,
      source_kind: :original_attested,
      original_only: true,
      open: true,
      legal_effect: :not_verified,
      financial_settlement: :none
    }

    put_in(state, [:commercial_source_lineage, Access.key({ch, p["obligation_id"]})], source)
  end

  @doc "An assignment changes source lineage irrevocably for original-only proof."
  def assigned(%Envelope{type: "ObligationAssigned", chapter_id: ch, payload: p} = env, state) do
    advance(state, {ch, p["obligation_id"]}, env, :assigned, true)
  end

  @doc "Directly signed discharge closes the business-obligation source."
  def discharged(%Envelope{type: "ObligationDischarged", chapter_id: ch, payload: p} = env, state) do
    advance(state, {ch, p["obligation_id"]}, env, :direct_discharge_attested, false)
  end

  @doc """
  Derive exactly the source-closure set of the pre-event obligation projection
  for legacy aggregate netting. Never mistake a residual net obligation for an
  originally signed and independently evidenced commercial invoice.
  """
  def netted(
        %Envelope{type: "NettingExecuted", chapter_id: ch, payload: p} = env,
        before,
        next_state
      ) do
    {a, b, den} = {p["party_a"], p["party_b"], p["denomination"]}

    closed =
      for {{^ch, id}, %{open: true, denomination: ^den} = ob} <- before.obligations,
          {ob.debtor_id, ob.creditor_id} in [{a, b}, {b, a}],
          do: {ch, id}

    advanced =
      Enum.reduce(closed, next_state, fn key, acc ->
        advance(acc, key, env, :legacy_netting_closed, false)
      end)

    case p["residual_obligation_id"] do
      nil ->
        advanced

      residual ->
        record = %{
          original_signed_core_digest: nil,
          latest_signed_core_digest: signed_core_digest(env),
          source_revision: 1,
          source_kind: :legacy_netting_residual,
          original_only: false,
          open: true,
          legal_effect: :not_verified,
          financial_settlement: :none
        }

        put_in(advanced, [:commercial_source_lineage, Access.key({ch, residual})], record)
    end
  end

  @doc """
  Original-only source eligibility is a conservative read projection. It is
  NOT a current authority, contract, banking or discharge decision.
  """
  def original_only?(%{commercial_source_lineage: rows}, chapter, id) do
    match?(
      %{source_kind: :original_attested, original_only: true, source_revision: 1, open: true},
      rows[{chapter, id}]
    )
  end

  def original_only?(_, _, _), do: false

  defp advance(state, key, env, kind, remains_open) do
    update_in(state, [:commercial_source_lineage, Access.key(key)], fn previous ->
      %{
        previous
        | latest_signed_core_digest: signed_core_digest(env),
          source_revision: previous.source_revision + 1,
          source_kind: kind,
          original_only: false,
          open: remains_open
      }
    end)
  end

  defp signed_core_digest(env) do
    {:ok, bytes} = Envelope.signing_bytes(env)
    :crypto.hash(:sha256, bytes)
  end
end
