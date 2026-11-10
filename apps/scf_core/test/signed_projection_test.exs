defmodule ScfCore.SignedProjectionTest do
  use ExUnit.Case, async: true

  alias ScfCore.{Ledger, SignedProjection, Statements}

  @book %{chapter: "chapter-dz", entity: "entity-dz", first_year: 2026}
  @document %{"id" => "fixture-piece", "sha256" => <<1::256>>}

  defp row(sequence, type, payload) do
    %{
      ref: %{
        sequence: sequence,
        digest: :crypto.hash(:sha256, <<sequence::64>>),
        event_id: "event-#{sequence}",
        chapter: @book.chapter,
        stream_id: "fixture/#{type}",
        stream_sequence: 1,
        type: type
      },
      payload: Map.put(payload, "entity_id", @book.entity)
    }
  end

  defp invoice(sequence \\ 1) do
    row(sequence, "InvoiceIssued", %{"invoice_id" => "I-42", "amount_minor" => 15_125})
  end

  defp link(%{ref: ref}), do: %{"sequence" => ref.sequence, "digest" => ref.digest}

  defp recognize(sequence, source, overrides \\ %{}) do
    row(
      sequence,
      "ScfServiceRevenueRecognizedV1",
      Map.merge(
        %{
          "invoice" => link(source),
          "currency" => "DZD",
          "tva_treatment" => "no_tva",
          "date" => "2026-12-31",
          "document" => @document
        },
        overrides
      )
    )
  end

  defp reversal(sequence, source, date, overrides \\ %{}) do
    row(
      sequence,
      "ScfEntryReversedV1",
      Map.merge(
        %{
          "target" => link(source),
          "date" => date,
          "currency" => "DZD",
          "document" => %{@document | "id" => "reversal-piece"}
        },
        overrides
      )
    )
  end

  defp close(sequence, date \\ "2026-12-31") do
    row(sequence, "ScfFiscalYearClosedV1", %{"through" => date, "document" => @document})
  end

  defp replay(rows), do: SignedProjection.replay(rows, @book)

  test "fresh replay and redelivery preserve exact source links and SCF reports" do
    invoice = invoice()
    posting = recognize(2, invoice)
    rows = [invoice, posting, close(3)]

    assert {:ok, result} = replay(rows)
    assert {:ok, ^result} = replay(rows)
    assert {:ok, ^result} = replay(rows ++ [posting, close(3)])

    assert result.postings[2] == %{
             source: posting.ref,
             invoice: invoice.ref,
             document: @document,
             reverses: nil
           }

    assert [%{piece: "fixture-piece"}] = Ledger.entries(result.ledger)
    assert Ledger.balances(result.ledger) == %{"411" => 15_125, "706" => -15_125}
    assert %{total_debit: 15_125, total_credit: 15_125} = Ledger.trial_balance(result.ledger)
    assert %{resultat_net: 15_125} = Statements.tcr(result.ledger)
    assert %{total_actif: 15_125, total_passif: 15_125} = Statements.bilan(result.ledger)
  end

  test "changed position, missing position and repeat economic posting all fail" do
    invoice = invoice()
    posting = recognize(2, invoice)
    conflict = put_in(posting.payload["date"], "2026-01-01")
    assert {:error, {2, :source_conflict}} = replay([invoice, posting, conflict])
    assert {:error, {2, :source_gap}} = replay([posting, invoice])

    assert {:error, {3, :invoice_already_recognized}} =
             replay([invoice, posting, recognize(3, invoice)])

    reissued = invoice(3)

    assert {:error, {4, :invoice_already_recognized}} =
             replay([invoice, posting, reissued, recognize(4, reissued)])
  end

  test "close is inclusive, immutable and sequential, with correction in the open year" do
    invoice = invoice()
    posting = recognize(2, invoice)
    prefix = [invoice, posting, close(3)]

    assert {:error, {4, :outside_open_fiscal_year}} =
             replay(prefix ++ [reversal(4, posting, "2026-12-31")])

    assert {:error, {4, :outside_open_fiscal_year}} =
             replay(prefix ++ [reversal(4, posting, "2028-01-01")])

    assert {:error, {4, :invalid_fiscal_close}} = replay(prefix ++ [close(4)])

    assert {:error, {3, :invalid_fiscal_close}} =
             replay([invoice, posting, close(3, "2027-12-31")])

    correction = reversal(4, posting, "2027-01-01")
    assert {:ok, result} = replay(prefix ++ [correction])
    assert result.ledger.closed_through == ~D[2026-12-31]
    assert result.postings[4].reverses == posting.ref
    assert result.postings[4].invoice == invoice.ref
    assert Ledger.balances(result.ledger) == %{}

    assert Ledger.balances(result.ledger, to: ~D[2026-12-31]) ==
             %{"411" => 15_125, "706" => -15_125}
  end

  test "reversals form linear, exact-reference chains" do
    invoice = invoice()
    posting = recognize(2, invoice)
    prefix = [invoice, posting]

    assert {:error, {3, :reversal_before_target}} =
             replay(prefix ++ [reversal(3, posting, "2026-12-30")])

    wrong_target = put_in(posting.ref.digest, <<0::256>>)

    assert {:error, {3, :missing_reversal_target}} =
             replay(prefix ++ [reversal(3, wrong_target, "2026-12-31")])

    correction = reversal(3, posting, "2026-12-31")

    assert {:error, {4, :entry_already_reversed}} =
             replay(prefix ++ [correction, reversal(4, posting, "2026-12-31")])

    restoration = reversal(4, correction, "2026-12-31")
    assert {:ok, result} = replay(prefix ++ [correction, restoration])
    assert result.postings[4].reverses == correction.ref
    assert Ledger.balances(result.ledger) == %{"411" => 15_125, "706" => -15_125}
  end

  test "source must be an earlier exact invoice in the same book" do
    invoice = invoice()
    unrelated = put_in(invoice.ref.chapter, "other-chapter")
    wrong_entity = put_in(invoice.payload["entity_id"], "other-entity")
    wrong_digest = put_in(invoice.ref.digest, <<0::256>>)
    wrong_type = put_in(invoice.ref.type, "ObligationRecorded")
    posting = recognize(2, invoice)

    for source <- [unrelated, wrong_entity, wrong_digest, wrong_type] do
      assert {:error, {2, :missing_invoice_evidence}} = replay([source, posting])
    end

    assert {:error, {1, :missing_invoice_evidence}} =
             replay([recognize(1, invoice(2)), invoice(2)])
  end

  test "document, currency, TVA treatment and real calendar dates are explicit" do
    invoice = invoice()

    for {overrides, error} <- [
          {%{"document" => nil}, :missing_document},
          {%{"document" => %{"id" => "piece"}}, :missing_document},
          {%{"currency" => nil}, :unsupported_currency},
          {%{"currency" => "EUR"}, :unsupported_currency},
          {%{"tva_treatment" => "standard"}, :unsupported_tva_treatment},
          {%{"date" => "2026-02-29"}, :invalid_accounting_date},
          {%{"date" => "2027-01-01"}, :outside_open_fiscal_year}
        ] do
      assert {:error, {2, ^error}} = replay([invoice, recognize(2, invoice, overrides)])
    end

    posting = recognize(2, invoice)

    assert {:error, {3, :unsupported_currency}} =
             replay([
               invoice,
               posting,
               reversal(3, posting, "2026-12-31", %{"currency" => "USD"})
             ])
  end

  test "invoices, credit memos, obligations and clearing alone create no accounting entries" do
    rows =
      ~w(CreditMemoIssued ObligationRecorded ObligationAssigned ObligationDischarged
         CommercialSetoffIntentRecordedV1 NettingExecuted)
      |> Enum.with_index(2)
      |> Enum.map(fn {type, sequence} -> row(sequence, type, %{}) end)

    assert {:ok, result} = replay([invoice() | rows])
    assert Ledger.entries(result.ledger) == []
    assert result.postings == %{}
  end
end
