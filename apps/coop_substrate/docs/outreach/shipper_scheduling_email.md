# Shipper scheduling email — template (the Face's first lane)

*Companion to `shipper_onepager.md`; inherits ALL of its preconditions (Face live,
corridors declared, counsel cleared, live corridor) plus one: **the carrier's
introduction has already happened** — this email schedules the working session it
opened; it never opens anything itself. Register: a logistics manager's inbox — brisk,
concrete, zero numbers in writing. One recipient, never a sequence.*

---

**Subject:** Setting up the [corridor] lane — one signature, then freight
*(alt: "[CARRIER first name]'s introduction — next step, 45 minutes")*

Hi **[first name]**,

Following up on **[CARRIER first name]**'s introduction. Short version of what I'd like
to put on your calendar: **45 minutes** to do the one piece of ceremony this
relationship ever needs, and to let you inspect the receipts machinery before a single
load rides on it.

The agenda, so nothing surprises you:

1. **The credit application — signed once.** After it, tenders inside your line move
   without further paperwork: quote back in moments on the live lane, tender, done.
   I'll send the application document ahead if you'd like your team to review first —
   whoever signs credit on your side should be in the room or on the signature line.
2. **Pick the trial lane.** [Corridor] is live; bring your hardest lane inside it if
   you want the honest test. A handful of loads, judged on the receipts.
3. **The receipts, demonstrated.** Ten minutes with your ops or audit person if you
   like: I'll export a custody record and have *your* side verify it independently —
   no access to our systems required. That property is the product; you should see it
   work before you rely on it.

A few slots on my end — say the word if none fit:

- **[option 1 — day, time, tz]**
- **[option 2]**
- **[option 3]**

Your office, ours, or a call — the signature can be done any of the three ways.

One expectation set now so it never disappoints later: **you won't get a rate sheet
from us, by email or otherwise.** Lanes quote live at tender time, inside declared
pricing corridors — the quote you get is the claim we stand behind, and it's always
current because it's never stale paper. If that discipline works for you, I think the
rest will too.

Thanks, **[first name]** —

**[FACE OPERATOR — name]**
**[phone]**
**[business address line]**

---

## Usage notes (internal — do not send)

- **Preconditions:** every box in the shipper one-pager's preconditions block, PLUS the
  signed introduction. If any is open, this email waits.
- **The sponsor's name:** [CARRIER] consented to the introduction — that signature
  covers opening the door, not indefinite invocation. Mention him in this first email
  (it's the context), then ask his comfort before further name-use. His standing is
  spent by the recorded introduction; don't overdraw it.
- **The credit application document** must be the counsel-cleared version — nothing
  improvised, no redlines accepted outside counsel's review.
- **If they ask for rates by email:** the answer is the paragraph above, verbatim if
  needed — quotes at tender time, in the system, on live lanes. No indications, no
  "ballparks." A ballpark in an email is an unresolvable claim with a paper trail
  (12 P1 applies to attachments too).
- **The verify demo:** rehearse it once — `export_stream` + `verify_export` on a real
  (member-consented or co-op-own) stream; their person runs the verification on THEIR
  laptop. If it doesn't land in ten minutes, it wasn't rehearsed.
- **Decline handling:** one thank-you, the door stays open, no sequence. Note it
  privately; the shipper never becomes data (they're a counterparty, not a member —
  nothing about them goes on any stream until a signed transaction puts it there
  bilaterally).

*Provenance: one-signature credit line then A-tier tenders → 04 §5 I5, 10 §4.6 (H3
once) · live-lane quoting inside declared corridors, no rate sheets → 10 §4.6 (H2
corridor constants), 12 §3/P1 · exportable independently-verifiable custody →
SUBSTRATE export_stream/verify_export (tested since 1A), 02 P1 · sponsor-edge
discipline → 07 §5 (edge-owner signed introduction; scope is the signature) ·
judged-on-receipts trial → shipper_onepager.md ask · bilateral-only shipper data →
04 §5 I2, 00 Art. II.3.*
