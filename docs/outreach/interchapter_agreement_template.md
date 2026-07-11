# Inter-chapter agreement — template for the bilateral signing

*The corpus gives inter-chapter relations three defaults and nothing more:
**non-interference, bilateral signed agreements, netting settlement** (04 §1, 00 Art.
IV.5). This template is the second — the first is its Article 1, and the third its
Article 5. Grant-shaped throughout: this agreement confers ONLY what it names; every
silence stays sovereign. Plain language on purpose — both rooms should be able to read
it aloud. [COUNSEL] reviews before the first signing; the mechanism articles are
already true in software.*

```
Between:  Chapter ____________ (chapter_id: ____________)
and:      Chapter ____________ (chapter_id: ____________)
Corridor: ____________ ↔ ____________          Effective: ____________
Agreement artifact hash (filled at signing): ____________
```

---

## Article 1 — Non-interference (the default, restated first)

Each chapter remains sovereign in its membership, governance, keys, constants, and
operations. Nothing in this agreement creates authority of either chapter over the
other, over the other's members, or over the other's equipment — and nothing here can:
the constitution both chapters ratified forbids it (00 Art. II, IV.5) and the software
each runs enforces it. Where this agreement is silent, the answer is "sovereign."

## Article 2 — The corridor (scope, and whose choice participation is)

This agreement concerns the named corridor's relay legs and staging between the two
localities — and **participation is per member, never per chapter**: no chapter commits
its members' trucks by signing this. A member participates by their own signed envelope
(their H5 policy, their ceiling), and bypass remains permitted to everyone, always
(00 Art. II.5). What the chapters agree here is only that the corridor is *offered*.

Named legs / yards in scope: ____________

## Article 3 — Custody at the boundary

Cross-chapter handoffs follow the one custody pattern (07 §3): signed,
condition-attested interchange, **both parties' signatures on the hook**.
*Machinery note, honest:* custody events are chapter-scoped today, so v0 records each
handoff as **mirrored attestations** — each chapter's member records their side on
their chapter's stream, each referencing the counterpart event's hash. Mirroring is a
this-agreement discipline until federation-scoped events are resolved (09 §1 — on the
joint agenda); disputes reduce, as always, to comparing adjacent condition reports.

## Article 4 — Commons and telemetry (what's shared; what can't be)

Each chapter grants the other's members read access to the corridor-relevant slice of
its **commons** (facility facts) and **telemetry** (k-gated aggregates, contributor
floors intact — the k-gate travels with the data). **Edges — customers, lanes,
contacts — are not grantable by this or any agreement**: they are sovereign *member*
data (07 §5), not chapter property; no signature below can move them, and the type
system agrees.

Granted commons/telemetry scope: ____________

## Article 5 — Settlement (the third default)

Money never moves on any chapter's substrate — that is not a term, it is a property.
Inter-member obligations across the corridor settle bilaterally and externally;
**like-denomination netting is the intended rail** (04 §1, 02 §6.3), recorded here as
the settlement method both chapters will adopt when the cross-chapter obligation
machinery exists (designed, unbuilt, waits for the first real need — second-chapter
kit, machinery notes). Until then: bilateral, external, attested — like everything.

## Article 6 — Mutual witness (the clause the machinery makes possible)

Each chapter will, at an agreed cadence (____________), deliver its published
checkpoint to the other, and each will hold the other's. **A sovereign counterpart is
the ideal external witness**: neither chapter can quietly rewrite a history the other
holds a sealed head of. This clause costs one file exchange per period and buys both
memberships the strongest tamper-evidence available to either.

## Article 7 — Members of both

A person may hold membership in both chapters: two records, two accounts, never merged
(1B design). Conduct standing is earned and judged per chapter; a censure in one is
information the other may weigh, never a sentence it must import. **Cross-chapter
shareholding stays at its default: no** (04 §1) — revisiting that is a constitutional
conversation, not a corridor term.

## Article 8 — Disputes, amendment, exit (legible, like everything)

- **Disputes between the chapters**: good-faith conference of the two governances;
  no federation arbiter exists or is created here. Member-conduct matters stay with
  the home chapter's standing review.
- **Amendment**: a new agreement artifact, mirror-signed like the original; the old
  version stands as history.
- **Exit**: either chapter, by signed notice, ____ days; in-flight corridor loads
  complete under this agreement's terms; granted commons access ends at termination;
  Article 6's held checkpoints are kept (history doesn't un-witness). No penalty,
  no hostage terms — the exit is legible or the agreement is void in spirit.

## The signing (mechanics — existing machinery, both logs)

```
[ ] this document finalized → canonical bytes → Artifacts.put → the hash above
[ ] each governance appends, on ITS OWN log:
      CharterConstantDeclared{ name: "interchapter/<corridor>/agreement",
                               value: <artifact hash>, note: <counterpart chapter_id> }
    — mirror events, hash-identical artifact, each side's own signature ceremony
    (machinery note: a dedicated agreement event type is a later nicety; the
    declared-constant pattern carries it today with full provenance)
[ ] both chapters emit + exchange checkpoints (Article 6 begins at the signing table)
[ ] each room's verification sheet: any member of either chapter can confirm both
    signings from the two logs and the one shared artifact hash
```

---

*Provenance: the three defaults → 04 §1, 00 Art. IV.5 · per-member participation +
bypass → 00 Art. II.5, H5 envelopes (10 §2) · custody pattern + mirrored v0 → 07 §3,
second-chapter kit machinery notes, 09 §1 open · commons/telemetry/edges classes →
07 §5 (edges sovereign BY TYPE) · netting intent → 02 §6.3, 04 §1 · mutual witness →
Log.checkpoint/verify_checkpoint (1D, tested) · dual membership + shareholding default
→ 1B design, 04 §1 · content-addressed mirror signing → Artifacts + declared-constant
pattern, both since 2A–2C.*
