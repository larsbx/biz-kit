defmodule CoopSubstrate.ProcurementContractTest do
  use CoopSubstrate.LogCase, async: false

  alias CoopSubstrate.{
    Log,
    Procurement,
    ProcurementContract,
    ProcurementFixture,
    ProcurementTestClock
  }

  alias ProcurementFixture, as: F

  defmodule Evidence do
    @behaviour CoopSubstrate.ProcurementContractEvidence

    @impl true
    def resolve(scope, ref, now) do
      case Application.fetch_env!(:coop_substrate, :procurement_contract_test_evidence) do
        {^scope, ^ref, ^now, facts} -> {:ok, facts}
        _ -> {:error, :evidence_unavailable}
      end
    end
  end

  setup do
    f = F.setup()

    assert {:ok, [_]} =
             Log.append(
               F.event(f, "ProcurementBusinessEnrolledV1", %{
                 "cooperative_id" => "coop",
                 "business_id" => "cooperative-company",
                 "active" => true,
                 "evidence_ref" => "private-cooperative-enrollment",
                 "expected_version" => 0
               })
             )

    Application.put_env(:coop_substrate, :procurement_contract_evidence, Evidence)

    on_exit(fn ->
      Application.delete_env(:coop_substrate, :procurement_contract_evidence)
      Application.delete_env(:coop_substrate, :procurement_contract_test_evidence)
    end)

    %{f: f}
  end

  test "disclosed paid wakalah is validated without changing the ledger or admission gate", %{
    f: f
  } do
    r = prepare(f, "wakalah")
    install(f, r, facts(f, r))
    head = Log.head()
    gate = Log.gate()
    events = Log.read_all()

    assert {:ok, receipt} = Procurement.review_contract(f.context, r)

    assert %{
             status: :validated_inert,
             version: 1,
             family: "wakalah",
             request_revision: 4,
             doctrinal_adoption: :undetermined,
             civil_applicability: :undetermined,
             runtime_activation: :inactive
           } = receipt

    assert {:ok, receipt.record_digest} == ProcurementContract.commitment(receipt.scope, r)
    assert {:ok, other_digest} = ProcurementContract.commitment({"other", "coop", "request-1"}, r)
    refute other_digest == receipt.record_digest
    refute Map.has_key?(receipt, :evidence_ref)
    assert {:ok, ^receipt} = Procurement.review_contract(f.context, r)
    assert {:ok, request} = Procurement.contract_review_request(f.context, r)
    assert {:error, :snapshot_requests_are_not_log_events} = Log.append(request)

    assert {:error, _} =
             F.submit(f, "accounting", 4, %{"receipt" => "validated_inert"})

    assert Log.head() == head
    assert Log.gate() == gate
    assert Log.read_all() == events
  end

  test "wakalah refuses missing, revoked, expired and mismatched mandates and invoices", %{f: f} do
    r = prepare(f, "wakalah")
    e = facts(f, r)

    for mandate <- [nil, %{e.mandate | revoked: true}] do
      install(f, r, %{e | mandate: mandate})

      assert {:error, :current_agency_mandate_required} =
               Procurement.review_contract(f.context, r)
    end

    for patch <- [
          %{expires_at_ms: f.now},
          %{valid_from_ms: r["agreed_at_ms"] + 1},
          %{purchase_limit_minor: 11_999},
          %{service_limit_minor: 499},
          %{principal_id: "merchant"},
          %{agent_id: "buyer"},
          %{currency: "EUR"}
        ] do
      install(f, r, %{e | mandate: Map.merge(e.mandate, patch)})
      assert {:error, :agency_mandate_out_of_scope} = Procurement.review_contract(f.context, r)
    end

    install(f, r, %{e | title: %{e.title | owner_id: r["cooperative_business_id"]}})
    assert {:error, :member_ownership_required} = Procurement.review_contract(f.context, r)

    install(f, r, %{e | purchase: %{e.purchase | basis: :fully_allocated_service_cost}})
    assert {:error, :unsupported_agency_purchase_cost} = Procurement.review_contract(f.context, r)

    install(f, r, %{e | purchase: %{e.purchase | buyer_id: r["cooperative_business_id"]}})
    assert {:error, :purchase_invoice_mismatch} = Procurement.review_contract(f.context, r)
  end

  test "principal musawamah and tawliyah require title before resale and distinct pricing bases",
       %{f: f} do
    r = prepare(f, "musawamah")
    e = facts(f, r)
    install(f, r, %{e | purchase: %{e.purchase | goods_minor: 11_000}})
    assert {:ok, %{family: "musawamah"}} = Procurement.review_contract(f.context, r)

    claimed = %{r | "acquisition_minor" => 12_000}
    install(f, claimed, e)

    assert {:error, :unsupported_acquisition_cost} =
             Procurement.review_contract(f.context, claimed)

    r = %{claimed | "family" => "tawliyah"}
    install(f, r, e)
    assert {:ok, %{family: "tawliyah"}} = Procurement.review_contract(f.context, r)

    for title <- [
          nil,
          %{e.title | owner_id: r["member_id"]},
          %{e.title | possessed_at_ms: r["agreed_at_ms"]},
          %{e.title | possessed_at_ms: r["agreed_at_ms"] + 1}
        ] do
      install(f, r, %{e | title: title})

      assert {:error, :seller_title_and_possession_required_before_resale} =
               Procurement.review_contract(f.context, r)
    end

    install(f, r, %{e | resale_invoice: %{e.resale_invoice | buyer_id: r["supplier_id"]}})
    assert {:error, :resale_invoice_mismatch} = Procurement.review_contract(f.context, r)

    for purchase <- [
          %{e.purchase | goods_minor: 11_500},
          %{e.purchase | basis: :fully_allocated_service_cost}
        ] do
      install(f, r, %{e | purchase: purchase})
      assert {:error, :unsupported_acquisition_cost} = Procurement.review_contract(f.context, r)
    end

    install(f, r, %{e | service_cost_minor: 499})
    assert {:error, :unsupported_service_cost} = Procurement.review_contract(f.context, r)
  end

  test "review is bound to the current accepted order, exact terms and active operator", %{f: f} do
    r = prepare(f, "wakalah")
    e = facts(f, r)
    install(f, r, e)

    for patch <- [%{"request_revision" => 3}, %{"quote_revision" => 2}, %{"family" => "tawliyah"}] do
      assert {:error, :contract_order_mismatch} =
               Procurement.review_contract(f.context, Map.merge(r, patch))
    end

    assert {:error, :invalid_contract_record} =
             Procurement.review_contract(f.context, %{r | "supplier_id" => r["member_id"]})

    assert {:error, :invalid_contract_record} =
             Procurement.review_contract(f.context, %{r | "version" => 2})

    assert {:error, :invalid_contract_record} =
             Procurement.review_contract(f.context, %{
               r
               | "service_minor" => 9_007_199_254_740_991
             })

    assert {:error, :unverified_contract_terms} =
             Procurement.review_contract(f.context, %{r | "service_minor" => 499})

    assert {:error, :evidence_unavailable} =
             Procurement.review_contract(f.context, %{r | "evidence_ref" => "other-case"})

    assert {:ok, request} = Procurement.contract_review_request(f.context, r)
    ProcurementTestClock.set(f.now + 1_000)
    assert {:error, :stale_procurement_admission_time} = Log.procurement_contract_review(request)
    ProcurementTestClock.set(f.now)

    assert {:ok, _} = F.submit(f, "payment_evidence", 4, %{"evidence_ref" => "payment"})
    assert {:error, :contract_order_mismatch} = Procurement.review_contract(f.context, r)

    assert {:ok, [_]} = Log.append(F.grant(f, false, 1))
    assert {:error, :procurement_forbidden} = Log.procurement_contract_review(request)
  end

  test "classification refuses when the private evidence owner is absent", %{f: f} do
    r = prepare(f, "wakalah")
    Application.delete_env(:coop_substrate, :procurement_contract_evidence)

    assert {:error, :procurement_contract_evidence_unavailable} =
             Procurement.review_contract(f.context, r)
  end

  defp prepare(f, family) do
    seller = if family == "wakalah", do: "merchant", else: "cooperative-company"
    assert {:ok, _} = F.submit(f, "request", 0, F.request(f))
    assert {:ok, _} = F.submit(f, "qualify", 1, %{"evidence_ref" => "qualification"})

    assert {:ok, _} =
             F.submit(f, "quote", 2, %{F.quote_attrs(f) | "merchant_business_id" => seller})

    assert {:ok, _} = F.submit(f, "accept", 3, F.acceptance())

    %{
      "version" => 1,
      "request_id" => "request-1",
      "request_revision" => 4,
      "quote_id" => "quote-1",
      "quote_revision" => 1,
      "family" => family,
      "cooperative_business_id" => "cooperative-company",
      "member_id" => "buyer",
      "supplier_id" => "merchant",
      "goods_ref" => "lot-1",
      "quantity" => 4,
      "currency" => "USD",
      "goods_minor" => 12_000,
      "acquisition_minor" => nil,
      "service_minor" => 500,
      "delivery_at_ms" => f.now + 5_000,
      "payment_due_at_ms" => f.now + 8_000,
      "delivery_site_ref" => "north-dock",
      "purchase_at_ms" => f.now - 2_000,
      "agreed_at_ms" => if(family == "wakalah", do: f.now - 3_000, else: f.now - 500),
      "evidence_ref" => "private-case"
    }
  end

  defp facts(f, r) do
    coop = r["cooperative_business_id"]
    buyer = if r["family"] == "wakalah", do: "buyer", else: coop

    purchase = %{
      seller_id: "merchant",
      buyer_id: buyer,
      goods_ref: "lot-1",
      quantity: 4,
      currency: "USD",
      at_ms: r["purchase_at_ms"],
      goods_minor: 12_000,
      basis: :original_goods_price
    }

    %{
      purchase: purchase,
      service_cost_minor: 500,
      resale_invoice: %{purchase | seller_id: coop, buyer_id: "buyer"},
      title: %{
        owner_id: buyer,
        goods_ref: "lot-1",
        quantity: 4,
        acquired_at_ms: f.now - 1_500,
        possessed_at_ms: f.now - 1_000
      },
      mandate: %{
        principal_id: "buyer",
        agent_id: coop,
        supplier_id: "merchant",
        goods_ref: "lot-1",
        currency: "USD",
        quantity_limit: 4,
        purchase_limit_minor: 12_000,
        service_limit_minor: 500,
        act: :purchase,
        revoked: false,
        valid_from_ms: f.now - 10_000,
        expires_at_ms: f.now + 1_000
      }
    }
  end

  defp install(f, record, facts) do
    scope = {f.context.chapter_id, f.context.cooperative_id, record["request_id"]}
    {:ok, digest} = ProcurementContract.commitment(scope, record)
    facts = Map.put_new(facts, :terms_digest, digest)

    Application.put_env(
      :coop_substrate,
      :procurement_contract_test_evidence,
      {scope, record["evidence_ref"], f.now, facts}
    )
  end
end
