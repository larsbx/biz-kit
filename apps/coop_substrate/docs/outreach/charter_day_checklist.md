# Charter-day checklist — the founding session's machinery

*The operational companion to `charter_session_agenda.md`: the agenda owns what the
room decides; this checklist owns everything that lets item 6 — the signing — work
the first time, in front of everyone. Its spine is the agenda's own sentence made
operational: **nothing binds until signed on the log at the table**, which means
the table needs a log, rehearsed commands, and a publication channel before anyone
sits down. One rule above the rest: **never debug at the table** — every append
the evening needs runs in a full dry run beforehand, because a signing ceremony
that stalls on a typo teaches the room the machinery is fragile, and the machinery
is the pitch.*

---

## 0 — Preconditions

- [ ] `demo_day_checklist.md` closed — this cohort saw the proof run
- [ ] The invitation letter's cohort confirmed; quorum understood: **whoever
      shows up IS the founding cohort** — no decision waits for the absent, and
      the deferred list catches what a thin room shouldn't decide
- [ ] Counsel engagement live (the agenda's item 7 expects a status, and the
      charter-on-log and entity documents must end up saying the same thing)
- [ ] Pre-reads went out with the invitation: the constitution (two pages), the
      founding-offer sketch, the how-the-signing-works paragraph

## 1 — The week before: the dry run (the checklist's whole reason)

- [ ] Every event item 6 needs, appended successfully on a SCRATCH store:
      `CharterConstantDeclared` per expected constant · `RoleKeyDeclared` per
      ceremony key · the 00-adoption record — command by command, by the person
      who'll run them at the table
- [ ] Where a `mix` task exists (`harness.keys gen <role>`, checkpoint), use it;
      where one doesn't, the one-off append script is WRITTEN AND REHEARSED NOW —
      the table is not a development environment
- [ ] The full sequence timed: if the signing can't run in the agenda's 30
      minutes on the scratch store, fix that this week
- [ ] The decision sheet printed: every agenda item with its blank AND its
      **default-if-undecided pre-filled** (the agenda's table) — an undecided
      item lands as its printed default, visibly, not as a hallway memory
- [ ] The verification instruction sheet drafted and tested on someone
      non-technical: one paragraph, `verify_checkpoint` in plain words

## 2 — Room setup (before anyone arrives)

- [ ] The log machine up: store reachable, `Log.verify_chains` → `:ok`, the
      rehearsed commands in a visible run-sheet
- [ ] The off-machine publication channel READY and tested — wherever the
      checkpoint goes (printed + posted, mailed to every attendee, the witness
      copy), it must work while the room watches, not after
- [ ] The key-ceremony station: a clean machine for **each new key holder to
      generate their own key, their hands on the keyboard** (seeds 0600, held
      by them, never displayed, never ours) — the TOFU succession is the day's
      real transfer of power and it must LOOK like one
- [ ] Printed: the constitution (one per seat) · the decision sheet · the
      deferred list (agenda item 5) ready to be read aloud
- [ ] The hub's two-minute demo recap cued (his phone, again — continuity from
      demo day)

## 3 — During: the chair's discipline

- [ ] The founder chairs and votes EXACTLY once — said out loud at the open,
      honored all night (Art. IV.1 applies to this room first)
- [ ] Timeboxes are real: when one expires undecided, the printed default is
      read aloud and the sheet marks it — "deciding to defer IS a decision, and
      a safe one"
- [ ] Objections to the constitution recorded verbatim as flagged amendment
      candidates — never argued past, never hallway-resolved
- [ ] Every decision lands on the decision sheet AS IT'S MADE, initialed by the
      chair — the sheet is item 6's input, and item 6 is not the time to
      reconstruct item 2
- [ ] The exclusions read aloud in the room's own voice (item 4): no
      recruitment pay, no share discounts, no guarantees

## 4 — The signing (item 6 — this is the meeting)

- [ ] Decisions become events in decision-sheet order, each append confirmed
      ACCEPTED before the next (the validity gate's rejection, if one fires, is
      handled by the rehearsed alternate — not improvised)
- [ ] The key ceremony: each governance/steward/checkpoint holder generates and
      declares at the station, one at a time, room watching — then the
      founder's bootstrap key's succession is stated plainly: **TOFU served its
      purpose; tonight it stops being special**
- [ ] The checkpoint: emitted, then **published off-machine while everyone
      watches** — the room sees the history seal
- [ ] The instruction sheet handed to every attendee: how any member verifies,
      from their own copy, that tonight happened exactly as they remember it
- [ ] The scratch-store dry-run data confirmed NOWHERE NEAR the real log
      (paranoia item; thirty seconds; worth it)

## 5 — After the room empties

- [ ] Minutes = the decision sheet + the event references, sent to every
      attendee (members-public, like the events themselves)
- [ ] Counsel sync per agenda item 7: the declared constants to counsel so the
      entity documents can match the log — the same-thing requirement now has
      its first real content
- [ ] Session two scheduled while the room's momentum is real (its gate:
      before the first thing bills)
- [ ] Misses-first, charter edition, written same-day: the append that needed
      its alternate, the timebox that blew, the default that landed because
      discussion ran dry — session two's opening material
- [ ] Tracker updates (who joined, who's deciding, who declined) — private dir,
      never the repo; a declined founding seat gets the no-re-pitch silence
      like every other no

---

*Provenance: agenda-owns-content / checklist-owns-machinery → single authority
(the paper owns its paper; `charter_session_agenda.md` governs the decisions) ·
nothing-binds-until-signed + checkpoint-while-watching → the agenda's item 6, the
substrate itself · constants-before-evaluation + defaults-closed printed →
00 Art. IV.2, 09 §3 · founder-votes-once → 00 Art. IV.1 · key ceremony: their
hands, their seeds, 0600, TOFU succession → SUBSTRATE.md §15.2, 1D genesis flag,
ops key hygiene (harness.keys) · dry-run-never-debug-at-the-table → the ops
CLI's own discipline extended to ceremony; rejection-handled-by-rehearsal → the
validity gate is a feature in the room, not an embarrassment · exclusions
aloud → 13 §2/§5 · no-re-pitch on declined seats → the series doctrine ·
verification sheet → Log.verify_checkpoint in plain words (the agenda's
instruction) · misses-first debrief → the series doctrine, charter edition.*
