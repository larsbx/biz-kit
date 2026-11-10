# SCF projection of the signed business ledger

## Canonical source

`CoopSubstrate.Log.append/2` verifies signed envelopes, evaluates the
admission gate with `TypeRegistry.validity_check/2`, assigns global and stream
positions, and persists the batch to EventStore. `Protocol.Envelope` signs
the event type, chapter, event ID, authorization reference, signer identities,
timestamp and payload. Its full-record hash also covers signatures and chain
placement. The projection cites the full-record hash and can resolve the
original authorization reference and signatures through that record.

`Log.replay/2` folds stored envelopes. For a new consumer use the audit and
paging pattern of `CoopSubstrate.SignedConsumerSource` instead of treating
an ordinary read as a verification step. Capture a fixed head, audit the
canonical prefix, read consecutive pages of at most 100 events, and require
the exact captured end and full-record hash. Anchor the audited prefix to
the canonical store and a trusted checkpoint for durable use. The existing
chain audit verifies signatures and chain consistency. The trust that
business validity was checked comes from canonical admission, so an
externally assembled chain is insufficient.

`InvoiceIssued` is a steward-signed Dispatch invoice. The canonical gate
requires the matching load and parties and recomputes lines and amount.
Its payload has no denomination, accounting recognition date or document
digest. An invoice, credit memo or recorded obligation on its own gives
this projection insufficient evidence to post. Setoff intents, legacy netting
and discharge events also have no posting rule in this prototype. SCF
reversals affect accounting entries only. The commercial obligation and
settlement paths continue to consume their own canonical events.

## Offline contract

`ScfCore.SignedProjection.replay/2` accepts normalized fixture rows from
sequence 1 and a fixed book profile (`chapter`, `entity`, `first_year`).
An authorized internal caller can run `CoopSubstrate.ScfReplaySource.capture/1`
and pass the returned `rows` to the fold. Capture audits the local log at a
fixed head, reads pages of up to 100 records, checks every global link and
requires the terminal digest to match the captured head. The caller supplies
a record limit up to 10,000. Capture fails without partial rows if the head
exceeds that limit or any page fails verification.

```elixir
with {:ok, %{head: head, rows: rows}} <- CoopSubstrate.ScfReplaySource.capture(1_000),
     {:ok, book} <- ScfCore.SignedProjection.replay(rows, profile) do
  {:ok, %{head: head, book: book}}
end
```

The reader retains the canonical full-record digest, event ID, chapter,
global sequence, stream ID, stream sequence and type. It unwraps canonical
byte values only for the proposed accounting reference and document digest
fields. Keep the captured rows inside the authorized process because the
prefix can contain data for other books. The fold trusts the reader and its
canonical admission boundary. Its fixture entry point also supports isolated
tests. The three SCF event names below are proposed contracts awaiting type
registration and signer grants. This operator-run path has no scheduler or
deployment wiring.

| Input | Projection rule |
| --- | --- |
| `InvoiceIssued` | Retain the exact earlier invoice in the selected chapter/entity. |
| `ScfServiceRevenueRecognizedV1` | Require `entity_id`, `invoice` (global sequence and digest), explicit `currency: DZD`, `tva_treatment: no_tva`, ISO accounting `date`, and `document` (ID and SHA-256). For one supported full-amount service recognition, debit 411 and credit 706 using the admitted invoice amount in centimes. The recognition declaration attests denomination and treatment. The fold performs no currency conversion or TVA determination. |
| `ScfEntryReversedV1` | Require `entity_id`, exact earlier posting `target`, DZD, accounting date and supporting document. Reverse all lines in the current open year, dated on or after the target. A posting can be reversed once. Reversing that reversal yields a linear, attributable chain. |
| `ScfFiscalYearClosedV1` | Require `entity_id`, ISO `through` and supporting document. Close only December 31 of the current open year. Start the next year on January 1. |
| Other events | Advance the global position without posting. |

Each book has its own entry namespace. IDs are deterministic from the global
sequence within one canonical ledger instance. Exact row redelivery is a
no-op. Conflicting rows, gaps, repeat recognition of an invoice ID, and
missing or mismatched evidence fail the fold with no partial book returned.
Provenance retains the full-record references for recognition, invoice and
each reversal target, plus the document ID and digest. The fold retains its
input rows to detect conflicting redelivery. A durable consumer should
store only the evidence and indexes required by its retention and replay
policy.

Use the existing SCF journal, trial balance and statements on the resulting
ledger. The existing bilan assumes one exercice with prior results already
carried forward. This fold supports dated corrections across year boundaries,
but does not implement opening balances, appropriation of prior results or
statutory multi-year reporting.

## Before any production wiring

* Define a versioned book profile and scope it to a canonical ledger identity
  and legal entity. Admit recognition, reversal and close through the same
  canonical log with separately authorized accounting roles. Bind the full
  source, document digest and accounting assertions in the signed core. Use
  admission-time policy for issuer identity, currency and TVA evidence,
  recognition eligibility, duplicate invoices and authorized close dates.
* Validate document bytes against the signed digest and enforce scoped
  evidence access and retention. A digest in a fixture demonstrates the
  link structure. Verification and durable retrieval of documents belong to
  the host. Persist the projected entries, provenance, mapping version and
  checkpoint atomically in a rebuildable read model. Resume only from a
  verified checkpoint, with quarantine and reporting blocked on incomplete
  replay.
* Have Algerian accounting and tax reviewers validate the entity-specific
  chart and invoice/TVA treatment, fiscal calendar, correction rules,
  carry-forward, comparative statements, filing outputs and computerized
  accounting controls. Review the record retention and statutory books
  requirements under Loi 07-11, the computerized accounting requirements
  under Décret 09-110, and recognition and presentation under the Arrêté of
  26 July 2008. The calendar-year and no-TVA fixture choices are prototype
  scope decisions. Test results provide software evidence.

Official texts

* [Loi 07-11, Journal officiel no. 74](https://www.joradp.dz/ftp/jo-francais/2007/f2007074.pdf)
* [Décret exécutif 09-110, Journal officiel no. 21](https://www.joradp.dz/FTP/jo-francais/2009/F2009021.pdf)
* [Arrêté of 26 July 2008, Journal officiel no. 19](https://www.joradp.dz/ftp/jo-francais/2009/f2009019.pdf)
