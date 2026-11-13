defmodule CoopSubstrate.ProducerCapitalPreview do
  @moduledoc """
  Inert, source-shaped producer cooperative capital proposals.

  This module does not issue shares, authenticate legal owners or agents,
  execute payments, append events, or certify civil-law or fiqh compliance.
  Every input and evidence reference is caller asserted. A positive preview
  is NOT a signed, approved, or effectful contract.

  The existing CapitalAccounts/PatronageRecorded projection is a distinct
  historical accrual model; its redeemable balance is NOT a membership share,
  cooperative NAV, or investment entitlement.

  The contract profiles are deliberately narrower than the complete
  2026-11-13 Hanbali contract taxonomy. The current project profile models
  named cash-funded co-ownership and a separate voluntary unit transfer,
  not a mudarabah, qard, lease-to-own, or universal profit-share.
  """

  @max 9_007_199_254_740_991
  @annual_schema "bizkit.producer-capital.annual-contribution-preview.v1"
  @project_schema "bizkit.producer-capital.project-snapshot-preview.v1"
  @buyout_schema "bizkit.producer-capital.unit-buyout-preview.v1"

  @annual_keys ~w(schema cooperative_id member_business_id membership_year currency amount_minor capital_class source_ref)a
  @project_keys ~w(schema project_id producer_business_id currency revision issued_units positions contract_profile profile_version adopted_profile_ref civil_review_ref title_ref ordinary_loss_rule principal_guarantee)a
  @position_keys ~w(owner_business_id serials)a
  @buyout_keys ~w(schema project_id expected_revision seller_business_id buyer_business_id serials currency per_unit_minor amount_minor valuation_ref appraisal_as_of expires_at seller_consent_ref buyer_consent_ref settlement_ref transfer_kind principal_guarantee fixed_return_minor)a

  @doc """
  Validate the stated annual USD 250 contribution, but never derive unit
  counts, a refundable balance, voting rights, or an equity NAV from cash.
  Those require separately adopted instruments and independent admission.
  """
  def annual_contribution(contribution) when is_map(contribution) do
    if annual_valid?(contribution) do
      {:ok,
       %{
         schema: @annual_schema,
         member_business_id: contribution.member_business_id,
         membership_year: contribution.membership_year,
         amount_minor: contribution.amount_minor,
         source_ref: contribution.source_ref,
         status: :held_for_legal_share_issuance_and_nav,
         equity_units_issued: 0,
         financial_authority: false
       }}
    else
      {:error, :invalid_annual_contribution}
    end
  end

  def annual_contribution(_), do: {:error, :invalid_annual_contribution}

  @doc """
  Compute a deterministic nonbinding producer acquisition of EXISTING units.

  Appraisal, consideration, current grants, consent, title, legal profile,
  securities classification, and source uniqueness are NOT authenticated.
  No default authorization or money/stock transfer is available.
  """
  def buyout(project, terms, now)
      when is_map(project) and is_map(terms) and is_integer(now) and now >= 0 do
    with :ok <- valid_project(project),
         :ok <- valid_buyout(project, terms, now) do
      next_positions = move(project.positions, project.producer_business_id, terms)

      {:ok,
       %{
         schema: @buyout_schema,
         project_id: project.project_id,
         source_revision: project.revision,
         proposed_revision: project.revision + 1,
         positions_before: canonical_positions(project.positions),
         positions_after: canonical_positions(next_positions),
         issued_units: project.issued_units,
         consideration_minor: terms.amount_minor,
         currency: terms.currency,
         terms_digest: commitment(project, terms),
         status: :unadmitted_requires_independent_evidence_and_authority,
         legal_effect: false,
         accounting_posted: false,
         funds_moved: false,
         title_transferred: false
       }}
    end
  end

  def buyout(_, _, _), do: {:error, :invalid_buyout}

  defp annual_valid?(c) do
    exact?(c, @annual_keys) and
      c.schema == @annual_schema and
      id?(c.cooperative_id) and id?(c.member_business_id) and
      c.cooperative_id != c.member_business_id and
      is_integer(c.membership_year) and c.membership_year in 2020..2100 and
      c.currency == "USD" and c.amount_minor == 25_000 and
      c.capital_class == "membership_equity_candidate" and ref?(c.source_ref)
  end

  defp valid_project(p) do
    allowed =
      exact?(p, @project_keys) and
        p.schema == @project_schema and id?(p.project_id) and
        id?(p.producer_business_id) and currency?(p.currency) and
        is_integer(p.revision) and p.revision >= 0 and
        is_integer(p.issued_units) and p.issued_units in 2..256 and
        p.contract_profile == "diminishing_musharakah_asset_coownership" and
        p.profile_version == 1 and
        ref?(p.adopted_profile_ref) and ref?(p.civil_review_ref) and
        ref?(p.title_ref) and
        p.ordinary_loss_rule == "capital_ownership_proportionate" and
        p.principal_guarantee == false and
        is_list(p.positions)

    if allowed and valid_positions?(p), do: :ok, else: {:error, :invalid_project_snapshot}
  end

  defp valid_positions?(p) do
    rows = p.positions

    Enum.all?(rows, fn row ->
      exact?(row, @position_keys) and id?(row.owner_business_id) and
        is_list(row.serials) and row.serials != [] and
        Enum.all?(row.serials, &is_integer/1)
    end) and
      Enum.uniq_by(rows, & &1.owner_business_id) == rows and
      Enum.any?(rows, &(&1.owner_business_id == p.producer_business_id)) and
      length(rows) >= 2 and
      rows
      |> Enum.flat_map(& &1.serials)
      |> Enum.sort()
      |> Kernel.==(Enum.to_list(0..(p.issued_units - 1)))
  end

  defp valid_buyout(p, t, now) do
    valid =
      exact?(t, @buyout_keys) and
        t.schema == @buyout_schema and
        t.project_id == p.project_id and
        t.expected_revision == p.revision and
        id?(t.seller_business_id) and
        t.seller_business_id != p.producer_business_id and
        t.buyer_business_id == p.producer_business_id and
        t.currency == p.currency and
        is_list(t.serials) and t.serials != [] and
        Enum.all?(t.serials, &is_integer/1) and
        length(Enum.uniq(t.serials)) == length(t.serials) and
        is_integer(t.per_unit_minor) and
        t.per_unit_minor > 0 and t.per_unit_minor <= @max and
        is_integer(t.amount_minor) and
        t.amount_minor > 0 and t.amount_minor <= @max and
        t.amount_minor == length(t.serials) * t.per_unit_minor and
        ref?(t.valuation_ref) and
        is_integer(t.appraisal_as_of) and t.appraisal_as_of <= now and
        is_integer(t.expires_at) and t.expires_at > now and
        ref?(t.seller_consent_ref) and ref?(t.buyer_consent_ref) and
        ref?(t.settlement_ref) and
        t.transfer_kind == "separate_voluntary_current_value_unit_sale" and
        t.principal_guarantee == false and t.fixed_return_minor == 0

    seller = Enum.find(p.positions, &(&1.owner_business_id == t.seller_business_id))

    if valid and seller != nil and Enum.all?(t.serials, &(&1 in seller.serials)),
      do: :ok,
      else: {:error, :invalid_buyout_terms}
  end

  defp move(rows, producer, t) do
    Enum.map(rows, fn row ->
      cond do
        row.owner_business_id == t.seller_business_id ->
          %{row | serials: row.serials -- t.serials}

        row.owner_business_id == producer ->
          %{row | serials: row.serials ++ t.serials}

        true ->
          row
      end
    end)
  end

  defp canonical_positions(rows) do
    rows
    |> Enum.map(fn r -> %{r | serials: Enum.sort(r.serials)} end)
    |> Enum.sort_by(& &1.owner_business_id)
  end

  defp commitment(p, t) do
    fields =
      [
        @buyout_schema,
        p.project_id,
        p.producer_business_id,
        p.currency,
        Integer.to_string(p.revision),
        Integer.to_string(p.issued_units),
        p.contract_profile,
        Integer.to_string(p.profile_version),
        p.adopted_profile_ref,
        p.civil_review_ref,
        p.title_ref,
        p.ordinary_loss_rule,
        Atom.to_string(p.principal_guarantee)
      ] ++
        Enum.flat_map(canonical_positions(p.positions), fn row ->
          [row.owner_business_id, Integer.to_string(length(row.serials))] ++
            Enum.map(row.serials, &Integer.to_string/1)
        end) ++
        [
          t.seller_business_id,
          t.buyer_business_id,
          Integer.to_string(length(t.serials))
        ] ++
        Enum.map(Enum.sort(t.serials), &Integer.to_string/1) ++
        [
          Integer.to_string(t.per_unit_minor),
          Integer.to_string(t.amount_minor),
          t.valuation_ref,
          Integer.to_string(t.appraisal_as_of),
          Integer.to_string(t.expires_at),
          t.seller_consent_ref,
          t.buyer_consent_ref,
          t.settlement_ref,
          t.transfer_kind,
          Atom.to_string(t.principal_guarantee),
          Integer.to_string(t.fixed_return_minor)
        ]

    fields
    |> Enum.map_join("", fn s -> "#{byte_size(s)}:#{s}" end)
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp exact?(m, keys) when is_map(m),
    do: Enum.sort(Map.keys(m)) == Enum.sort(keys)

  defp exact?(_, _), do: false

  defp id?(s) when is_binary(s),
    do: byte_size(s) in 1..128 and String.match?(s, ~r/\A[a-zA-Z0-9][a-zA-Z0-9._:-]*\z/)

  defp id?(_), do: false

  defp ref?(s) when is_binary(s),
    do: byte_size(s) in 1..256 and String.valid?(s) and String.trim(s) != ""

  defp ref?(_), do: false

  defp currency?(s) when is_binary(s), do: String.match?(s, ~r/\A[A-Z]{3}\z/)
  defp currency?(_), do: false
end
