# Runbook — Evaluating gate(D) in the Field

The founder's operational companion to `HARNESS.md` §5. The machinery is built and green
on synthetic data; this runbook is the sequence of *your* acts that makes `gate(D)` true
on real, consented evidence. Normative authority stays with `docs/corpus/` (11 §2, §4-D;
12 §3–§4; 13 §1, §4) and `HARNESS.md` — this document only orders the work.

**The shape of the whole thing:** 5–8 friendly carriers → consented interviews with the
published instrument → typed findings, corroborated across ≥ k people → a process model
you can't cherry-pick → your tier judgment, signed once → anonymized fixtures → prospects
into the funnel → `gate(D)` true → the D build brief gets cut. Every step lands as a
signed event; nothing here is a spreadsheet.

---

## Phase 0 — Before any contact (one sitting, at the keyboard)

**0.1 Counsel gates — check the [LEGAL] items that touch interviews** (brief §1):
- Recording consent statute for *each interviewee's state* (two-party states matter).
  The consent event carries a distinct `recording` flag; when in doubt, run interviews
  with `recording: false` and take typed notes — findings are G2 either way.
- Honorarium treatment: accrue freely now (`mix harness.honorarium accrue ...`); payout
  attestation is **unrepresentable** until counsel clearance is declared
  (`mix harness.honorarium clear 1 --note "<counsel ref>"` — and `clear 0` stops it
  again). `mix harness.honorarium list` is the tracker — a fold, never a spreadsheet
  (docs/honorarium_rail.md). Early-member standing remains the clean alternative
  (corpus 11 §6.2).
- No automated outbound voice, period — the mode isn't representable. Your own phone
  calls (`mode: "call"`) are fine.

**0.2 Leave key bootstrap** (recommended; ~15 minutes; SUBSTRATE.md §15):
1. Generate and **offline-back-up** three keypairs: governance, steward, checkpoint.
2. Append the genesis `RoleKeyDeclared` (governance, self-signed — trust-on-first-use),
   then declare the steward and checkpoint keys under it.
3. Emit `Log.checkpoint/3` and publish the blob somewhere outside the machine (a private
   gist, a second host, your phone) — that out-of-band genesis checkpoint is the TOFU
   mitigation, and every later checkpoint commits you to the history the interviews
   land in.
Skipping this leaves the chapter in bootstrap (any steward/governance signature passes).
It works, but your `SpecAdopted` signature means more with the registry closed.

**0.3 Declare the constants — before the first gate evaluation, retro-fit is void**
(00 Art. IV.2). Four `CharterConstantDeclared` events:

| Name | Meaning | Suggested start (yours to declare) |
|---|---|---|
| `harness/D/n` | interviews required | 5 (corpus: n_D ≈ 5–8) |
| `harness/D/c` | corroborated core claims required | 4 (≈ one per core D question) |
| `harness/D/d` | documents required | 5 (one real rate con per carrier) |
| `k` | independent sources per corroboration | 2 (3 if recruitment goes well) |

Declare conservatively; a later declaration can raise or lower them *forward* — visibly,
on-stream.

**0.4 Publish the instrument**: review `Harness.Instrument.seed_d/0`, edit if needed,
`Instrument.publish/4`. Question changes from now on are new versions — diffable, so
your own leading-question drift is auditable (11 §5).

## Phase 1 — Recruit the friendly five-to-eight (the critical path; weeks, not hours)

This is relationship work the corpus says cannot be spec'd (13 §8.2). Selection per the
hub score (13 §1): aged authority + clean record, 1–20 trucks, ideally one yard-owning
carrier (dual-pitch), one respected dispatcher, one driver-trainer type. Recruit where
the trust already lives — people who already call *you*.

Pitch discipline (12 §3): every claim you make must resolve to something declared or
demonstrable. You are asking for **an hour of their expertise about how dispatch really
works**, offering early-member standing (or a counsel-cleared honorarium), and being
explicit that the interview is also how the co-op finds its founding members — the
interview close *is* the invitation for hub-scored leads (13 §6). Do not promise rates,
volumes, or dates: the demo assets don't exist yet, and the narratives doc (13A) shows
the register — mechanism language, launch-state qualifiers.

## Phase 2 — The consent ceremony (per interviewee, ~5 minutes, before anything else)

Consent is **their** signature, not your checkbox (11 §1.2):
1. Generate a keypair for them; the seed is theirs — hand it over (a QR/printout they
   keep) and keep no copy beyond the session needs.
2. Walk the three classes in plain words: *synthesis* ("your answers shape the spec"),
   *anonymized_fixtures* ("redacted snippets become test data"), *prospect_record* ("we
   may follow up about membership"). They pick; partial grants are normal and the
   machinery respects them everywhere.
3. `recording: true` only where 0.1 cleared their state AND they say yes.
4. Append `InterviewConsentGranted` signed with *their* key. Tell them, truthfully:
   revocation is one signed event, and it atomically pulls their material out of every
   count, model, and future emission — including flipping the gate if they were
   load-bearing. That fact is your credibility.

One grant per person, terminal revocation: if someone revokes and returns, they come back
as a new `interviewee_ref` with fresh consent.

## Phase 3 — Conduct and capture (per interview, 45–90 minutes + same-day entry)

- Append `InterviewConducted` (mode `call`/`chat`/`form`), then work the published
  instrument's persona branch. The one answer that matters most, verbatim: **"what would
  you let software accept on your behalf, and where exactly does trust stop?"** — that
  sentence becomes an envelope default.
- Enter findings the same day as typed `FindingExtracted` events — one finding per fact,
  the nine kinds only. G2 is automatic; don't editorialize the `body`, quote them.
- Collect real documents via `Harness.collect_document/6` — rate cons, BOLs, invoices,
  a lease if offered. `doc_kind: "recording"` only lands with recording consent (the
  gate enforces it). Aim for ≥ 1 document per carrier (that's your `d_D`).
- Transcription/extraction assist: self-hosted models only, as
  `MachineExtractionRecorded` proposals; promote what's right into `FindingExtracted`
  by hand; demote hallucinations with `CorrectionRecorded`. A frontier model is
  unrepresentable until you (governance) append `FrontierModelUseDeclared` with a real
  dated trigger — declare it only if self-hosted transcription genuinely fails you.

## Phase 4 — Corroborate and flag (after interview ≥ 2, then rolling)

- When ≥ k *different people* attest the same process fact, append `Corroborated`
  (claim ref + their finding ids). The gate enforces independence — one talkative
  carrier's five findings are one source.
- Where they *disagree* (and they will — check-call cadence, acceptance timing), append
  `ConflictFlagged`. Conflicts are model content, not noise; never pick a winner
  silently (11 P4).
- Watch `Harness.counts("chapter-genesis", "D")` roll up. Interviews below target?
  Recruit more; do not lower the constants to fit the data you happen to have — that
  move is on-stream and it looks exactly like what it is.

## Phase 5 — Synthesize, classify, sign once (an afternoon, the judgment step)

1. `Synthesis.publish_model/4`, then read the model artifact end to end. Anyone can
   recompile it byte-identically — so can you: verify once, and know that curating
   evidence is off the table.
2. Write the classifier — your tier judgment per core claim, the distilled trust answers:
   `%{"h" => "H1".."H6"}` where a human must sign, `%{"enveloped" => true}` where their
   own stated envelopes cover it, `"contested"` where a ruling is needed (09), and
   *leave unclassified anything you're unsure of* — it lands block-tier, which is the
   safe wrong answer (10 §0).
3. `Synthesis.publish_spec/3`; read the spec — nodes, tiers, the adversarial cases
   seeded from their horror stories.
4. Append `SpecAdopted` with all three hashes, signed with the **governance** key. This
   is the pipeline's one human signature (11 §1.4). It binds the *latest* model — if new
   findings landed since compilation, recompile first; the gate will refuse a stale hash.

## Phase 6 — Fixtures and funnel (same afternoon)

- Build fixture files from the collected documents: redact names, companies, lanes,
  MC/DOT, contacts. Put every sensitive literal you redacted into the **denylist** you
  pass `Fixtures.publish/7` — the regexes catch the mechanical classes; the denylist is
  where your knowledge of what's sensitive lives. One violation kills the whole set,
  which is the point. Only `anonymized_fixtures`-consented interviews may be sources.
- Emit `FunnelProspectEmitted` for every `prospect_record`-consented interviewee, track
  `D` (or `L`/`Y` for the driver/yard conversations). These records are what the 12
  onboarding engine and the 13 founding campaign consume — re-check consent before any
  actual contact.

## Phase 7 — The gate

```elixir
CoopSubstrate.Harness.gate("chapter-genesis", "D")   # {:ok, true} or the honest reason
```

`{:ok, true}` → append `BuildStarted{section: "D"}`, emit and publish a fresh checkpoint,
and cut the D build brief (dispatch agents on the first carrier's exhaust — a new
hand-off, per the pattern of `docs/handoff_harness_d.md`).

`{:ok, false}` → `Harness.counts/2` names the short leg. `{:error,
:constants_undeclared}` → Phase 0.3 was skipped.

**Standing caution:** the gate is live, not a certificate. A load-bearing revocation
flips it false afterward — which is correct behavior, and one more reason the founding
relationships matter more than the count.

---

## Operating — the CLI (the primary path)

Every phase above is one `mix harness.*` command; rejections print the gate's error term
verbatim, and each atom names the runbook step that was skipped. Set `HARNESS_KEYS_DIR`
first (0600 seed files live there — flagged temporary custody, 08 §9).

```sh
mix harness.keys genesis                 # 0.2 — TOFU + declarations + checkpoint blob
mix harness.constants --n 5 --c 4 --d 5 --k 2        # 0.3 — typed confirmation
mix harness.instrument publish           # 0.4 — the corpus 11 §4-D seed tree

mix harness.consent --ref IV-1 --classes synthesis,anonymized_fixtures,prospect_record \
    [--recording]                        # 2 — run WITH them; hand over the printed seed
mix harness.interview --id I-1 --interviewee IV-1 --mode call        # 3
mix harness.findings findings.json       # 3 — batch; or --id/--interview/--kind/--body
mix harness.document --interview I-1 --kind rate_confirmation path/to/ratecon.pdf
mix harness.corroborate C-accept F-1 F-7 # 4 — needs k distinct people
mix harness.conflict X-timing F-2 F-9    # 4
mix harness.status                       # 4/7 — gate + counts + short legs, named

mix harness.model publish && mix harness.model show   # 5 — read it end to end
mix harness.spec publish classifier.json # 5 — prints the three hashes
mix harness.adopt --spec <hex> --defaults <hex> --model <hex>   # 5 — THE signature

mix harness.fixtures publish fixtures/ --denylist denylist.txt --sources I-1,I-2  # 6
mix harness.prospect --ref P-1 --interviewee IV-1 --interview I-1                 # 6
mix harness.build_started                # 7 — lands only when the gate is true
mix harness.checkpoint                   # 7 — publish the blob outside this machine
mix harness.revoke --ref IV-1 --seed-file their.seed   # anytime; terminal; may flip the gate
```

## Appendix — signing events from iex (fallback)

If the CLI is unavailable, the same acts can be signed by hand. Paste this once per
`iex -S mix` session:

```elixir
alias CoopSubstrate.{Crypto, Log}
alias CoopSubstrate.Protocol.Envelope

sign_and_append = fn role, key_id, seed, type, payload ->
  {:ok, env} =
    Envelope.new(%{
      chapter_id: "chapter-genesis", type: type, payload: payload,
      signers: [%{role: role, pubkey: Crypto.pubkey_from_seed(seed), key_id: key_id}],
      timestamp_ms: System.system_time(:millisecond)
    })
  {:ok, signed} = Envelope.sign(env, key_id, seed)
  Log.append(signed)
end

# New keypair (e.g. for an interviewee — hand them the seed):
{pub, seed} = Crypto.generate_keypair()
```

Multi-signer events (`MembershipConfirmed`, the obligation rail) follow the same shape
with two signers and two `Envelope.sign/3` passes. Every rejection you'll see is the gate
telling you which runbook step was skipped — the error atoms are named for this document's
phases (`:constants_undeclared`, `{:no_active_consent, _}`, `{:not_independent, _, _}`,
`{:model_hash_mismatch, _}`, `{:harness_gate_not_passed, _}`).
