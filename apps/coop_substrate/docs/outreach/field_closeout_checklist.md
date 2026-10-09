# Field-phase closeout checklist — when gate(D) evaluates

*The kickoff checklist's bookend. Run when synthesis and fixtures days are closed
and the gate is about to be asked its question for real. Two rules give this
checklist its spine: **the verdict is the fold's, not yours** — you run a command
and read it, in the open, with the checkpoint sealing what it read from; and
**both branches get equal dignity** — a false gate closed honestly is the phase
succeeding at its actual job, which was never to reach D; it was to make reaching
D mean something. One absolute: **the constants stand.** A shortfall is answered
with more evidence, never a smaller bar — retro-fit is void by constitution, and
threshold-shaving after seeing the counts is retro-fit with extra steps.*

---

## 0 — Preconditions (all of these, or this checklist waits)

- [ ] `synthesis_day_checklist.md` closed: SpecAdopted on the log, binding the
      latest model hash
- [ ] `fixtures_day_checklist.md` closed: FixtureSetPublished on the log
- [ ] All interview material classified; every revocation honored and excluded
      (spot-check: no revoked interviewee appears in any count below)
- [ ] The declared constants confirmed AS DECLARED — `mix harness.constants`
      (`harness/D/n`, `harness/D/c`, `harness/D/d`, `k`) — and their declaration
      events PRE-DATE this evaluation. Read them aloud; they are about to judge
      you.

## 1 — The evaluation, in the open

- [ ] Checkpoint FIRST: `mix harness.checkpoint <blob_path>` — the sealed head
      the verdict will be read against; publish/exchange per the witness habit
- [ ] `mix harness.status --section D` — the cockpit line: **gate verdict +
      counts + short legs**, computed from the log, nobody's opinion
- [ ] Read the verdict to whoever is in the room, verbatim, including the counts
- [ ] Record the evaluation in the weekly status (final edition, below) with the
      checkpoint reference — the verdict and its evidence travel together

## 2A — If gate(D) = true: the handoff (this checklist's job ENDS here)

- [ ] `mix harness.build_started --section D` — the marker the software refused
      to record until now; its acceptance is itself the gate's proof
- [ ] Open `dispatch_kickoff_checklist.md` — **it owns everything after the
      marker**; nothing about the build belongs in a field-phase document
- [ ] Proceed to §3 — the field loop closes the same way on both branches

## 2B — If gate(D) = false: the honest shortfall

- [ ] Name the gap in counts, from the status line: which legs are short
      (interviews / corroborated / documents / spec / fixtures) and by how much —
      numbers, not adjectives
- [ ] **The constants stand.** No amendment conversation happens within sight of
      this shortfall — a bar moved while you're under it never reads as
      governance again, to anyone
- [ ] The extension plan is MORE EVIDENCE: which prospects re-enter the tracker,
      which corroborations are genuinely pending vs. gone, what the next capture
      window is — the recruitment tracker reopens; the kickoff checklist's
      cadence resumes
- [ ] If the honest answer is that the evidence isn't coming: the phase PAUSES,
      declared as such to governance and interviewees — a paused phase with its
      integrity intact restarts; a gamed one doesn't
- [ ] Governance gets the shortfall as aggregate counts against declared
      constants, with the checkpoint reference — the gate holding under pressure
      IS the report

## 3 — Closing the loop with interviewees (both branches, every consenting interviewee)

- [ ] The closure message, per interviewee, honest per branch: what their
      material became — **[true: "the process model and spec your interviews
      shaped are adopted; the anonymized fixture set is published; the build
      they gate has started"] [false: "the evidence bar we declared up front
      hasn't been met yet; here's where it stands, and your material stands
      exactly where your consent put it"]**
- [ ] Said in both cases: their consent remains THEIRS — revocation stays
      unilateral and terminal, exactly as at the ceremony; the phase ending
      changes nothing about that
- [ ] Honorarium statement, per interviewee, from the log (`mix
      harness.honorarium list`): what accrued in their name, and the payout
      truth verbatim — **still gated on counsel's clearance; nothing pays until
      that event exists, and they'll hear when it does**
- [ ] No recruitment content in any closure message — membership conversations
      have their own documents and their own time

## 4 — Materials security (the promises, kept physically)

- [ ] Raw notes, debriefs, and the recruitment tracker: archived in the private
      dir, OUTSIDE the repo, per the standing rule — verify nothing leaked into
      git along the way (`git log --stat` spot-check)
- [ ] Recordings and held documents: retention/destruction per each consent's
      classes — destruction attested where destruction is due
- [ ] Key hygiene audit: HARNESS_KEYS_DIR seeds 0600, interviewee seeds NEVER in
      our possession (they held their own — confirm no exceptions accumulated),
      no seed in any log, shell history, or backup
- [ ] The seed slips: unused blanks destroyed; issued ones were theirs to keep

## 5 — The final weekly status (last edition, both branches)

- [ ] The verdict + counts + checkpoint reference, verbatim from §1
- [ ] The phase's whole arc in aggregate: prospects → consents → interviews →
      corroborated → documents → findings → spec/fixtures state
- [ ] Misses-first, phase edition: what the field phase got wrong end to end —
      the capture days that slipped, the corroborations that stalled, the
      consent that was revoked and why if offered — ours first, as always
- [ ] Where the paper trail goes quiet: this is the LAST weekly status; what
      reporting exists next (build cadence or pause cadence) is the next
      document's business, named so nobody waits for a report that isn't coming

---

*Provenance: gate(D) = interviews ≥ n ∧ corroborated ≥ c ∧ documents ≥ d ∧
SpecAdopted ∧ FixtureSetPublished → HARNESS.md, `harness_gate/3`
(harness_gate_test) · constants-before-evaluation, retro-fit void → 00 Art. III.3;
threshold-shaving = retro-fit → the constitution applied to its own thresholds ·
verdict from the fold, marker unrepresentable until true → Ops CLI
(harness.status, harness.build_started; ops_pipeline_test) · checkpoint witness →
Log.checkpoint (1D), the mutual-witness habit · revocation terminal, exclusion at
fold time → 2A machinery, consent ceremony's promise · honorarium payout gated →
honorarium_rail.md, counsel Tier 1.2 · privacy floor (private dir, seeds, 0600) →
the standing constraints, ops CLI discipline · both-branches dignity +
misses-first → the series doctrine; the handoff split → dispatch_kickoff_checklist
owns the build (single authority) · bookend → kickoff_checklist.md.*
