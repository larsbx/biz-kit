defmodule CoopSubstrate.ProcurementContract do
  @moduledoc """
  Read-only classification of an accepted procurement revision. Evidence is
  resolved by the configured private evidence owner after Log authenticates
  the operator. This module neither stores evidence nor grants authority.
  """

  alias CoopSubstrate.Canonical

  @max_minor 9_007_199_254_740_991
  @fields ~w(version request_id request_revision quote_id quote_revision family cooperative_business_id
             member_id supplier_id goods_ref quantity currency goods_minor acquisition_minor service_minor
             delivery_at_ms payment_due_at_ms delivery_site_ref purchase_at_ms agreed_at_ms evidence_ref)

  @doc false
  def validate(record, row, now, resolve) do
    with :ok <- shape(record, now),
         :ok <- match_order(record, row),
         {:ok, digest} <- commitment(row.scope, record),
         {:ok, evidence} <- resolve.(record["evidence_ref"]),
         :ok <- terms(record, evidence, digest),
         :ok <- classify(record, evidence, now) do
      {:ok,
       %{
         status: :validated_inert,
         version: 1,
         family: record["family"],
         scope: row.scope,
         request_revision: row.version,
         record_digest: digest,
         observed_at_ms: now,
         doctrinal_adoption: :undetermined,
         civil_applicability: :undetermined,
         runtime_activation: :inactive
       }}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_contract_evidence}
    end
  end

  @doc "Canonical commitment for case-scoped terms assent."
  def commitment({chapter, cooperative, request}, record) do
    Canonical.hash(%{
      "purpose" => "procurement-contract-review-v1",
      "chapter_id" => chapter,
      "cooperative_id" => cooperative,
      "request_id" => request,
      "record" => record
    })
  end

  defp shape(r, now) when is_map(r) do
    parties = Enum.map(~w(cooperative_business_id member_id supplier_id), &r[&1])

    if Enum.sort(Map.keys(r)) == Enum.sort(@fields) and r["version"] === 1 and
         r["family"] in ~w(wakalah musawamah tawliyah) and
         Enum.all?(
           ~w(request_id quote_id cooperative_business_id member_id supplier_id
                      goods_ref delivery_site_ref evidence_ref),
           &id?(r[&1])
         ) and
         Enum.uniq(parties) == parties and
         Enum.all?(
           ~w(request_revision quote_revision quantity delivery_at_ms
                      purchase_at_ms agreed_at_ms payment_due_at_ms),
           &positive?(r[&1])
         ) and
         Enum.all?(~w(goods_minor service_minor), &minor?(r[&1])) and
         (is_nil(r["acquisition_minor"]) or minor?(r["acquisition_minor"])) and
         r["goods_minor"] + r["service_minor"] <= @max_minor and
         r["purchase_at_ms"] <= now and r["agreed_at_ms"] <= now and
         r["delivery_at_ms"] >= max(r["agreed_at_ms"], r["purchase_at_ms"]) and
         r["payment_due_at_ms"] >= r["agreed_at_ms"] do
      :ok
    else
      {:error, :invalid_contract_record}
    end
  end

  defp shape(_, _), do: {:error, :invalid_contract_record}

  defp match_order(r, %{phase: phase, version: version, request: request, accepted_quote: quote})
       when phase in [:accepted, :fulfilled] and is_map(quote) do
    seller = if r["family"] == "wakalah", do: r["supplier_id"], else: r["cooperative_business_id"]

    if r["request_revision"] == version and r["quote_id"] == quote.quote_id and
         r["quote_revision"] == quote.revision and seller == quote.merchant_business_id and
         r["goods_minor"] == quote.total_minor and r["member_id"] == request.buyer_business_id and
         r["quantity"] == request.quantity and r["currency"] == request.currency and
         r["delivery_at_ms"] <= request.needed_by_ms do
      :ok
    else
      {:error, :contract_order_mismatch}
    end
  end

  defp match_order(_, _), do: {:error, :accepted_procurement_required}

  # The evidence owner attests current party authority and assent to these exact
  # terms, including the cooperative's legal-entity mapping and any separate fee.
  defp terms(r, %{terms_digest: digest, service_cost_minor: service}, digest) do
    if service === r["service_minor"], do: :ok, else: {:error, :unsupported_service_cost}
  end

  defp terms(_, _, _), do: {:error, :unverified_contract_terms}

  defp classify(%{"family" => "wakalah"} = r, evidence, now) do
    with :ok <- mandate(r, evidence[:mandate], now),
         :ok <- purchase(r, evidence[:purchase], r["member_id"], r["goods_minor"]),
         :ok <- agency_purchase_basis(evidence[:purchase]),
         :ok <- agency_title(r, evidence[:title], now),
         true <- is_nil(r["acquisition_minor"]) and r["agreed_at_ms"] <= r["purchase_at_ms"] do
      :ok
    else
      false -> {:error, :invalid_agency_terms}
      {:error, _} = error -> error
    end
  end

  defp classify(r, evidence, _now) do
    with :ok <- purchase(r, evidence[:purchase], r["cooperative_business_id"], nil),
         :ok <- title(r, evidence[:title]),
         :ok <- resale_invoice(r, evidence[:resale_invoice]) do
      cost_basis(r, evidence.purchase)
    end
  end

  defp mandate(
         r,
         %{
           principal_id: principal,
           agent_id: agent,
           supplier_id: supplier,
           goods_ref: goods,
           currency: currency,
           quantity_limit: quantity,
           purchase_limit_minor: spend,
           service_limit_minor: fee,
           act: :purchase,
           valid_from_ms: first,
           expires_at_ms: last,
           revoked: false
         },
         now
       ) do
    if principal == r["member_id"] and agent == r["cooperative_business_id"] and
         supplier == r["supplier_id"] and goods == r["goods_ref"] and currency == r["currency"] and
         positive?(quantity) and minor?(spend) and minor?(fee) and
         positive?(first) and positive?(last) and first <= r["agreed_at_ms"] and now < last and
         r["quantity"] <= quantity and r["goods_minor"] <= spend and r["service_minor"] <= fee do
      :ok
    else
      {:error, :agency_mandate_out_of_scope}
    end
  end

  defp mandate(_, _, _), do: {:error, :current_agency_mandate_required}

  defp purchase(
         r,
         %{
           seller_id: seller,
           buyer_id: buyer,
           goods_ref: goods,
           quantity: quantity,
           currency: currency,
           at_ms: at,
           goods_minor: amount
         },
         expected_buyer,
         expected_amount
       ) do
    if seller == r["supplier_id"] and buyer == expected_buyer and goods == r["goods_ref"] and
         quantity === r["quantity"] and currency == r["currency"] and at === r["purchase_at_ms"] and
         minor?(amount) and (is_nil(expected_amount) or amount === expected_amount) do
      :ok
    else
      {:error, :purchase_invoice_mismatch}
    end
  end

  defp purchase(_, _, _, _), do: {:error, :purchase_invoice_required}

  defp agency_purchase_basis(%{basis: :original_goods_price}), do: :ok
  defp agency_purchase_basis(_), do: {:error, :unsupported_agency_purchase_cost}

  defp agency_title(
         r,
         %{owner_id: owner, goods_ref: goods, quantity: quantity, acquired_at_ms: acquired},
         now
       ) do
    if owner == r["member_id"] and goods == r["goods_ref"] and quantity === r["quantity"] and
         positive?(acquired) and r["purchase_at_ms"] <= acquired and acquired <= now do
      :ok
    else
      {:error, :member_ownership_required}
    end
  end

  defp agency_title(_, _, _), do: {:error, :member_ownership_required}

  defp title(r, %{
         owner_id: owner,
         goods_ref: goods,
         quantity: quantity,
         acquired_at_ms: acquired,
         possessed_at_ms: possessed
       }) do
    if owner == r["cooperative_business_id"] and goods == r["goods_ref"] and
         quantity === r["quantity"] and positive?(acquired) and positive?(possessed) and
         r["purchase_at_ms"] <= acquired and acquired <= possessed and
         possessed < r["agreed_at_ms"] do
      :ok
    else
      {:error, :seller_title_and_possession_required_before_resale}
    end
  end

  defp title(_, _), do: {:error, :seller_title_and_possession_required_before_resale}

  defp resale_invoice(r, %{
         seller_id: seller,
         buyer_id: buyer,
         goods_ref: goods,
         quantity: quantity,
         currency: currency,
         goods_minor: amount
       }) do
    if seller == r["cooperative_business_id"] and buyer == r["member_id"] and
         goods == r["goods_ref"] and quantity === r["quantity"] and
         currency == r["currency"] and amount === r["goods_minor"] do
      :ok
    else
      {:error, :resale_invoice_mismatch}
    end
  end

  defp resale_invoice(_, _), do: {:error, :resale_invoice_required}

  defp cost_basis(%{"family" => "musawamah", "acquisition_minor" => nil}, _), do: :ok

  defp cost_basis(
         %{"family" => "tawliyah", "acquisition_minor" => cost, "goods_minor" => cost},
         %{goods_minor: cost, basis: :original_goods_price}
       ),
       do: :ok

  defp cost_basis(_, _), do: {:error, :unsupported_acquisition_cost}

  defp id?(v), do: is_binary(v) and Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9._-]{0,127}\z/, v)
  defp positive?(v), do: is_integer(v) and v > 0 and v <= @max_minor
  defp minor?(v), do: is_integer(v) and v >= 0 and v <= @max_minor
end
