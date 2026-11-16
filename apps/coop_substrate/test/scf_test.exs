defmodule CoopSubstrate.ScfTest do
  @moduledoc """
  SCF books on the canonical Log: governance opens a book and grants a
  scoped accountant key; the accountant's signed écritures are admitted only
  if `ScfCore.SignedProjection` would post them, and the gate's book equals an
  offline replay of the audited log (one rulebook for admission and rebuild).
  """
  use CoopSubstrate.LogCase, async: false
  alias CoopSubstrate.{Log, ProcurementTestClock, Scf, ScfReplaySource}

  @now 1_800_000_000_000
  @chapter "scf-test"
  @entity "sarl-atlas"
  @doc_ref %{"id" => "statuts-2026", "sha256" => {:bytes, <<7::256>>}}
  @capital [
    %{"side" => "debit", "account" => "512", "amount_minor" => 1_000_000_00},
    %{"side" => "credit", "account" => "101", "amount_minor" => 1_000_000_00}
  ]

  setup do
    ProcurementTestClock.set(@now)
    :ok = Scf.register_types!()
    gov = new_member("governance", "gov")
    accountant = new_member("scf_accountant", "accountant-key")

    context = %{
      chapter_id: @chapter,
      entity_id: @entity,
      accountant_id: "comptable",
      key_id: accountant.signer.key_id,
      seed: accountant.seed,
      grant_version: 1,
      session_expires_at_ms: @now + 3_600_000
    }

    {:ok, [_]} =
      Log.append(
        signed_event(
          gov,
          "RoleKeyDeclared",
          %{"role" => "governance", "key_id" => "gov", "pubkey" => {:bytes, gov.signer.pubkey}},
          chapter_id: @chapter,
          timestamp_ms: @now
        )
      )

    {:ok, gov: gov, accountant: accountant, context: context}
  end

  defp governance(%{gov: gov}, type, payload),
    do:
      signed_event(gov, type, Map.put(payload, "entity_id", @entity),
        chapter_id: @chapter,
        timestamp_ms: @now
      )

  defp open_book(f, year \\ 2026),
    do: Log.append(governance(f, "ScfBookOpenedV1", %{"first_year" => year}))

  defp grant(f, active, expected),
    do:
      Log.append(
        governance(f, "ScfAccountantGrantedV1", %{
          "accountant_id" => "comptable",
          "key_id" => f.accountant.signer.key_id,
          "pubkey" => {:bytes, f.accountant.signer.pubkey},
          "active" => active,
          "expires_at_ms" => @now + 7_200_000,
          "expected_version" => expected
        })
      )

  defp ready(f) do
    {:ok, [_]} = open_book(f)
    {:ok, [_]} = grant(f, true, 0)
    :ok
  end

  defp entry(overrides \\ %{}),
    do:
      Map.merge(
        %{
          "journal" => "OD",
          "label" => "Apport en capital",
          "date" => "2026-03-05",
          "currency" => "DZD",
          "document" => @doc_ref,
          "lines" => @capital
        },
        overrides
      )

  defp post(f, command_id, attrs \\ entry()),
    do: Scf.post(f.context, "ScfJournalEntryPostedV1", command_id, attrs)

  test "a granted accountant's écriture is admitted, read back and survives a restart", f do
    :ok = ready(f)
    assert {:ok, posted} = post(f, "c-1")

    assert {:ok, book} = Scf.book(f.context)
    assert book.entity_id == @entity and book.first_year == 2026 and book.open_year == 2026

    assert ScfCore.Ledger.balances(book.ledger) == %{
             "101" => -1_000_000_00,
             "512" => 1_000_000_00
           }

    assert [%{id: id, piece: "statuts-2026"}] = ScfCore.Ledger.entries(book.ledger)
    assert id == "signed-scf-v1:#{posted.global_seq}"

    before = Scf.state(Log.gate())
    :ok = restart_log()
    assert Scf.state(Log.gate()) == before
    assert :ok = Log.verify_chains()
  end

  test "an entry the SCF rules refuse never reaches the log", f do
    :ok = ready(f)
    head = Log.head()
    [debit, credit] = @capital
    unbalanced = [debit, %{credit | "amount_minor" => 1}]

    assert {:error, {:reject, 0, {:invalid_entry, [{:unbalanced, 1_000_000_00, 1}]}}} =
             post(f, "c-1", entry(%{"lines" => unbalanced}))

    assert {:error, {:reject, 0, :outside_open_fiscal_year}} =
             post(f, "c-2", entry(%{"date" => "2027-01-02"}))

    assert {:error, {:reject, 0, :unsupported_currency}} =
             post(f, "c-3", entry(%{"currency" => "EUR"}))

    assert Log.head() == head
  end

  test "authority: no book, no grant, foreign key, expired session and revocation are refused",
       f do
    assert {:error, {:reject, 0, :scf_forbidden}} = post(f, "c-1")
    {:ok, [_]} = open_book(f)
    assert {:error, {:reject, 0, :scf_book_already_open}} = open_book(f, 2027)
    assert {:error, {:reject, 0, :scf_forbidden}} = post(f, "c-1")
    assert {:error, :scf_forbidden} = Scf.book(f.context)
    {:ok, [_]} = grant(f, true, 0)

    rogue = new_member("scf_accountant", f.accountant.signer.key_id)
    forged = %{f.context | seed: rogue.seed}

    assert {:error, {:reject, 0, :scf_forbidden}} =
             Scf.post(forged, "ScfJournalEntryPostedV1", "c-1", entry())

    expired = %{f.context | session_expires_at_ms: @now - 1}

    assert {:error, {:reject, 0, :scf_authority_expired_or_replaced}} =
             Scf.post(expired, "ScfJournalEntryPostedV1", "c-1", entry())

    assert {:error, _} = grant(f, true, 0)
    {:ok, [_]} = grant(f, false, 1)
    assert {:error, {:reject, 0, :scf_forbidden}} = post(f, "c-1")
    assert {:error, :scf_forbidden} = Scf.book(f.context)
  end

  test "a non-governance signer cannot open books or grant keys", f do
    impostor = new_member("governance", "gov")

    assert {:error, {:reject, 0, :scf_governance_required}} =
             Log.append(
               governance(%{f | gov: impostor}, "ScfBookOpenedV1", %{"first_year" => 2026})
             )
  end

  test "retries are idempotent by command id; changed content under the same id conflicts", f do
    :ok = ready(f)
    {:ok, original} = post(f, "c-1")
    head = Log.head()

    ProcurementTestClock.set(@now + 2_000)
    assert {:ok, ^original} = post(f, "c-1")
    assert Log.head() == head
    assert {:error, :scf_idempotency_conflict} = post(f, "c-1", entry(%{"label" => "autre"}))

    assert {:error, :scf_requires_singleton_batch} =
             Log.append([
               elem(Scf.envelope(f.context, "ScfJournalEntryPostedV1", "c-2", entry()), 1),
               elem(Scf.envelope(f.context, "ScfJournalEntryPostedV1", "c-3", entry()), 1)
             ])
  end

  test "signatures outside the admission window are refused", f do
    :ok = ready(f)
    {:ok, stale} = Scf.envelope(f.context, "ScfJournalEntryPostedV1", "c-1", entry())
    ProcurementTestClock.set(@now + 31_000)
    assert {:error, {:reject, 0, :stale_scf_admission_time}} = Log.append(stale)
  end

  test "contrepassation and clôture go through the same gate; the closed year is intangible", f do
    :ok = ready(f)
    {:ok, posted} = post(f, "c-1")
    target = %{"sequence" => posted.global_seq, "digest" => {:bytes, Scf.digest!(posted)}}

    reversal = %{
      "target" => target,
      "date" => "2026-03-06",
      "currency" => "DZD",
      "document" => %{@doc_ref | "id" => "avoir-1"}
    }

    assert {:ok, _} = Scf.post(f.context, "ScfEntryReversedV1", "c-2", reversal)

    assert {:error, {:reject, 0, :entry_already_reversed}} =
             Scf.post(f.context, "ScfEntryReversedV1", "c-3", reversal)

    assert {:ok, _} =
             Scf.post(f.context, "ScfFiscalYearClosedV1", "c-4", %{
               "through" => "2026-12-31",
               "document" => %{@doc_ref | "id" => "pv-cloture"}
             })

    assert {:error, {:reject, 0, :outside_open_fiscal_year}} = post(f, "c-5")
    assert {:ok, _} = post(f, "c-6", entry(%{"date" => "2027-01-02"}))

    {:ok, book} = Scf.book(f.context)
    assert book.open_year == 2027
    assert book.ledger.closed_through == ~D[2026-12-31]
  end

  test "the admitted book equals an offline replay of the audited log", f do
    :ok = ready(f)
    {:ok, _} = post(f, "c-1")

    {:ok, _} =
      post(
        f,
        "c-2",
        entry(%{
          "lines" => [
            %{"side" => "debit", "account" => "60", "amount_minor" => 300_00},
            %{"side" => "debit", "account" => "4456", "amount_minor" => 57_00},
            %{"side" => "credit", "account" => "512", "amount_minor" => 357_00}
          ]
        })
      )

    {:ok, %{rows: rows}} = ScfReplaySource.capture(1_000)

    {:ok, replayed} =
      ScfCore.SignedProjection.replay(rows, %{
        chapter: @chapter,
        entity: @entity,
        first_year: 2026
      })

    {:ok, book} = Scf.book(f.context)
    assert book.ledger == replayed.ledger
    assert book.postings == replayed.postings
  end
end
