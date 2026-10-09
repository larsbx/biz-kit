# Carrier scheduling email — template (the Face's first tenders)

*The member-side twin of `shipper_scheduling_email.md`: schedules a member carrier's
onboarding onto the live brokerage — envelope ceremony, open-book walkthrough, payment
terms said plainly. Recipient is already a member (likely founding cohort, possibly
with the back-office running on their books). Preconditions: Face live (the full
shipper-page set) AND this carrier's coverage current — check `tenderable(c)` BEFORE
sending; inviting someone the gate will refuse is a wasted afternoon and a bruise.
Zero numbers, no volume promises, ever.*

---

**Subject:** Your lanes, your floor, your signature — Face tenders are live
*(alt: "The brokerage is running — one sitting to set your terms")*

Hi **[first name]**,

The co-op's freight desk is live on the [corridor] lane(s), and loads are starting to
move. Before a single tender comes your way, there's one sitting I owe you — about an
hour — because nothing here auto-enrolls you in anything:

1. **Your envelope — the part that's yours alone.** You sign the policy that governs
   what the system may accept on your behalf: which lanes, what rate floor, what
   equipment, which counterparty classes. **I'll bring a draft built from what you
   told us in your interview — your own words about where trust stops — and you
   tighten or loosen every line of it.** Out-of-bounds tenders always come to you as
   questions, never as bookings. You can revise or revoke the whole thing any day,
   and revocation takes effect the moment it's signed.
2. **The open-book view — the reason this brokerage exists.** You're an owner: you see
   the margin on every load you haul for the Face, itemized, and your share of it
   accruing as patronage. Ten minutes on your own screen, your own numbers.
3. **Payment terms, said now and not at invoice time:** the Face pays **when the
   shipper pays** — that's the honest stage we're at. Faster-pay is a designed program
   that switches on when the co-op's evidence gates say the capital is there, not
   before, and I'd rather tell you that today than surprise you in 40 days.
4. **Coverage check** — your certificate has to be fresh for the system to tender you
   at all; we'll confirm it's green while we're at it (it's a hard gate, including
   for founders — especially for founders).

And the standing rule, restated so it's never in doubt: **routing your freight through
the Face is voluntary, load by load, forever.** Take what works, skip what doesn't,
and nobody will ever ask why. The desk earns your loads or it doesn't deserve them.

Slots on my end — say the word if none fit:

- **[option 1 — day, time, tz]**
- **[option 2]**
- **[option 3]**

Your yard or a call; the signature works either way.

Thanks, **[first name]** —

**[FACE OPERATOR — name]**
**[phone]**

---

## Usage notes (internal — do not send)

- **Preconditions:** Face live (full set) · membership active · `tenderable(carrier)`
  currently TRUE — verify before sending; if coverage is stale, the first conversation
  is the renewal, not this one.
- **The envelope draft** comes from their harness interview's co-3 findings and the
  adopted spec's envelope defaults — *proposed*, never pre-activated (the D-brief's
  first invariant: defaults are proposals the carrier signs; the system may narrow
  nothing and widen nothing).
- **Never promise volume or specific loads.** Tenders flow by the declared allocation
  rules (capability + track record + the fairness floor) — if asked "how much freight
  will I get," the honest answer is the mechanism, not a number.
- **Pay-when-paid goes in EVERY first conversation** — a member who learns it at
  invoice time was failed by this email. Quick-pay's evidence gate can be named
  ("when pledged member capital clears the program's gate") without a date.
- **Patronage accrual** is per the session-two charter decisions — show the accrual
  view; don't paraphrase the weights, display them.
- **If they decline the envelope entirely:** fine, permanently — a member with no
  envelope simply receives every tender as a question (all-R). Sovereignty includes
  the right to automate nothing.

*Provenance: envelope = H5, their signature, out-of-envelope escalates, atomic
revocation → 10 §2/P5–P6, D-brief invariant 1 · defaults from co-3 + adopted spec →
11 §1.3, EnvelopeDefaultsV1 · open-book to members + patronage → 04 §5 I2/I7,
session-two accrual decisions · pay-when-paid at T1, quick-pay T2-gated → 04 §5 I5,
05 §4, 03 · tenderable hard gate → 06 §2 (fail-closed, no founder exceptions) ·
allocation by capability/grade/fairness floor → 04 §5 I3 · voluntary routing forever →
04 §5 I7, 00 Art. II.5 · no volume promises → 12 §3/P1 · all-R-by-choice → 10 §2 H5
("the carrier decides its own autonomy level").*
