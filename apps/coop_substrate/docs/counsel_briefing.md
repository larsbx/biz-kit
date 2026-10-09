# Counsel briefing memo — the [LEGAL] gate items, triaged

```
From:  [FOUNDER]
To:    [COUNSEL]
Re:    Freight cooperative project — legal questions, triaged by when they block
Date:  [____]
```

**How to read this.** The project is a member-owned freight cooperative whose rules are
enforced by software: prohibitions are made *unrepresentable* in the system rather than
policed after the fact. Where an item below says **"plugs in as: declared constant /
enabled mode,"** it means your clearance doesn't become a memo in a drawer — it becomes
a signed configuration event with your reference attached, and the software refuses the
gated act until that event exists. Several conservative defaults are already hard-coded
closed (no automated voice calls, no honorarium payouts, no fund movement of any kind);
we are asking you to tell us which doors may open and how.

**Triage:** Tier 1 blocks work happening *this month* (interviews with 5–8 carriers).
Tier 2 blocks the first software going live on one carrier's real books. Tier 3 blocks
programs that are designed and documented but deliberately dormant. Please work top-down;
nothing in Tier 3 is urgent.

---

## Tier 1 — blocks the interview field phase (now)

**1.0 Field-phase legal posture (the question you'd ask first).** No entity exists yet;
the design (docs/corpus/04) charters cooperative entities later, member-ratified. During
the interview phase, one individual is: conducting recorded/noted interviews under a
consent framework, holding interviewees' business documents, and accruing (not paying)
small honoraria. *Deliverable:* whether to operate as an individual, form an LLC now, or
otherwise — and any interim insurance you'd want. *Plugs in as:* nothing mechanical;
this shapes everything else's answer.

**1.1 Recording consent, per state.** Interviews may be audio-recorded ONLY where the
interviewee separately consents; the software structurally refuses a recording artifact
without that flag. *Deliverable:* for the states where our first carriers sit
**[FOUNDER: list them]**, confirm one-party vs two-party status and any script language
you want spoken. *Plugs in as:* the runbook 0.1 checklist; where unconfirmed, the
recording offer is deleted from the script and notes-only is used.

**1.2 Honorarium treatment and payout.** We accrue a small thank-you amount per
interview on the ledger; **payouts are unrepresentable** until a clearance event carrying
your reference is declared (and can be un-declared, stopping payouts again).
*Deliverable:* may we pay; in what form (cash/check/gift card); 1099 or de-minimis
posture; any per-person cap you want us to respect. *Plugs in as:*
`honorarium/payout_cleared` declared constant, note = your reference. The alternative
already in use — early-member standing instead of money — is assumed clean; flag if not.

**1.3 The consent & retention structure (review, not redesign).** Interviewees sign
consent cryptographically with a key only they hold; they choose use-classes (design
input / anonymized test data / membership follow-up); revocation is unilateral, terminal,
and automatically excludes their material from every computation and future use. One
deliberate property to bless or adjust: the ledger is **append-only** — revoked material
is *sealed* (unusable, uncountable, never published; bilateral-only visibility), not
erased, while all out-of-ledger copies (recordings, documents) are physically destroyed.
*Deliverable:* confirm this "sealed not shredded" posture against any applicable
deletion rights for our states/subjects (business-practice interviews of owners, not
consumers), and review the consent script (docs/outreach/consent_ceremony_script.md).
*Plugs in as:* script edits; consent-class definitions.

## Tier 2 — blocks the dispatch tool going live on a real carrier's books (next quarter, roughly)

**2.1 Dunning & collection wording, per state.** The tool will draft (never send —
v0 renders artifacts a human reviews and sends) invoice reminders escalating through
declared rungs; formal demand letters always require a human signature. *Deliverable:*
state-law constraints on commercial (B2B) collection wording for our operating states;
template language if you want it. *Plugs in as:* the rendered-artifact templates; the
rung definitions.

**2.2 Detention/accessorial invoicing posture.** Detention charges are computed from
signed arrive/depart evidence against declared free-time terms and appear as invoice
line items (not demands). *Deliverable:* confirm the line-item-with-evidence posture is
clean B2B practice; anything you want on the artifact. *Plugs in as:* invoice template.

**2.3 Outbound transmission.** v0 sends nothing (manual import in, operator-sent
artifacts out). Before we automate email/EDI transmission on a carrier's behalf:
*Deliverable:* what authorization language the carrier signs for us to transmit in
their name. *Plugs in as:* an envelope (member-signed policy) template — the H5 pattern.

**2.4 Interview data licensing hygiene (light).** All interview/document material is
consent-covered (above). Separately, the *onboarding engine* design ingests public
datasets (FMCSA census, parcel records) — **not built yet**; per-source terms review is
gated to when it is. *Deliverable now:* none — listed so you know it's coming.

## Tier 3 — designed, documented, dormant (engage when we say a program is waking)

**3.1 Money-transmission boundary of the obligation rail** *(the most important
question on this page, eventually).* The system records member-to-member obligations,
assignments, and discharge attestations; **no funds ever move on-platform and no
payment event type exists** (structurally — the software cannot represent one).
Members settle externally and attest it. *Deliverable when engaged:* confirm this stays
outside money-transmitter licensing in our states, and the boundary conditions we must
never cross. Ref: docs/corpus/05 §1.2, P11.

**3.2 Land cooperative shares** [SECURITIES]. Member-only, NAV-priced,
non-transferable, redemption-gated shares in a land-holding co-op; narrative materials
exist with a risk wrapper and are NOT in public use. *Deliverable when engaged:*
exemption strategy before any public-facing use. Ref: docs/corpus/04 §3, 13A wrapper.

**3.3 Lease-to-own (driver graduation) instruments**, per state [LEGAL]; **3.4 worker
classification** for the service co-op and any facility staffing [LEGAL]; **3.5 broker
authority filing** — application packet PREPARED early, submission evidence-gated
[FMCSA]; **3.6 driver-activation verification chain** [FMCSA]; **3.7
fronting/captive terms and endorsement grade floor** [INSURANCE]; **3.8 outbound
voice-agent statutes per state** [LEGAL] — the mode is structurally absent from the
software until this clears; **3.9 per-source data licenses** for the onboarding engine
[LEGAL, per source]. Refs: docs/corpus/HANDOFF.md §4 and the owning documents.

---

**What we are NOT asking:** review of the cooperative charter, membership agreement, or
financial-instrument documents — none are in use; all are member-ratified later, and
each will come to you before first use, per the same gating discipline as everything
above. The system's own rule is "contested instruments enter at N (not-yet)" — your
open questions default everything to *closed*, so an unanswered item never becomes an
accidental yes.

*Attachments to send with this memo: docs/outreach/consent_ceremony_script.md ·
docs/outreach/seed_slip.html (printed) · docs/outreach/field_faq.md ·
docs/honorarium_rail.md · docs/corpus/HANDOFF.md (§4) — plus repo access if useful.*
