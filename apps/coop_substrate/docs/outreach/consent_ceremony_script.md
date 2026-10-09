# The consent ceremony — opening script

*Companion to runbook Phase 2 and the notes template. This is the first five minutes of
every interview, spoken. Suggested lines are quoted — use your own voice, keep the
promises EXACT: every claim below is something the machinery actually does, and nothing
more. Register per corpus 13A: mechanism language; the one place we must not oversell is
the place we're asking for trust.*

---

## Before they arrive

```
[ ] HARNESS_KEYS_DIR set; steward key exists (mix harness.keys list)
[ ] recording statute for THEIR state checked (runbook 0.1) — if unchecked, the
    recording ask below is DELETED, not improvised
[ ] seed handover medium ready: pen + printed slips (print `seed_slip.html` — blank by
    design; the key enters the paper only by their hand), or their phone camera
[ ] terminal open, font large enough to read across a table
[ ] optional demo prepared: nothing to prepare — it runs live (step 5)
```

## The script

### 1 — Framing (30 seconds)

> "Before we talk trucks, five minutes of housekeeping — and it's housekeeping I think
> you'll actually like. Everything you tell me today is yours. This step is where you
> decide what I'm allowed to do with it, and where you get the power to take it all
> back later. No obligation either way — if any of this feels off, we just have a
> normal conversation and I write nothing down."

### 2 — The three permissions (ask each separately; any mix is fine)

> "There are exactly three things I could do with your words. You say yes or no to each:
>
> **One — shaping the design.** Your answers get combined with other carriers' to write
> the spec for the dispatch tool. Your name isn't on it, but your words are in it.
>
> **Two — test data.** Redacted snippets — a rate con with every name and number
> stripped — become test files, so the software is tested against reality instead of
> my imagination. Nothing goes in until it passes an automatic scrubbing check.
>
> **Three — following up.** Permission for me to call you later about membership,
> because of this conversation. That's all it is — a permission to call."

*Record their yes/no per class. A partial grant is normal; note it in the header.*

### 3 — Recording (separate, only where 0.1 cleared their state)

> "Separate question entirely: may I record audio? Default is no — I take notes either
> way, and notes are plenty."

### 4 — The key (do it on screen, narrate as you type)

> "Now the part that makes this real instead of a pinky-promise. Watch the screen."

Run, with their choices:

```
mix harness.consent --ref IV-__ --classes <their yeses> [--recording]
```

> "What just happened: this machine generated a key — in front of you, just now — and
> used it to sign your permissions into the record. Here's the honest part: it was
> generated on **my** laptop, so the guarantee isn't the generation — it's this."

Point at the `SEED HANDOVER` banner:

> "That line is the key, and it's yours. Write it down —" *(hand them the slip / let
> them photograph it)* "— because the system will reject any change to your consent
> that isn't signed with it. **Including from me.** I don't keep a copy; after tonight
> I couldn't fake your revocation if I wanted to."

*Do not rush this. Watch them copy it. The slip:*

```
┌────────────────────────────────────────────────────────┐
│  YOUR CONSENT KEY — keep like a truck title            │
│  ref: IV-____                                          │
│  key: ________________________________________________ │
│  To take everything back: contact [FOUNDER], say the  │
│  word, bring this. One message; it's automatic.        │
└────────────────────────────────────────────────────────┘
```

### 5 — The revocation promise (and the offer to prove it)

> "If you ever want out: one signed message with that key, and everything of yours
> comes out of every count and every document — automatically, even if it knocks the
> whole project's legs out. That's not me being nice; the software refuses to work
> otherwise. Want to see it? Thirty seconds."

If yes — live, no preparation:

```
mix harness.consent --ref IV-demo-<n> --classes synthesis      # a throwaway
mix harness.revoke  --ref IV-demo-<n>                          # paste its seed
mix harness.status                                             # nothing counts it
```

> "That dummy consent just got revoked and the system already treats it as if it never
> spoke. Yours works the same."

### 6 — The one hard edge (say it before they ask)

> "One thing to know about that paper: **guard it**. If you lose it, the machine won't
> accept a revocation without it — that's the same property that stops me from faking
> one. If that ever happens, come to me and we'll deal with it face to face, but I
> won't pretend there's a button; today there isn't one."

*(True: consent revocation has no governance-recovery path — SUBSTRATE.md §8 flags key
recovery as open. Do not promise a mechanism that doesn't exist.)*

### 7 — Transition

> "Done. You're protected better than my own keys are. Now — tell me how a tender
> actually reaches you on a Tuesday."

*(Open the notes template; interview begins.)*

## If they decline everything

Thank them, mean it, and have the conversation anyway — off the record, as neighbors.
**Nothing goes on the log, nothing in the findings ledger, no interviewee_ref is ever
created.** A person who didn't consent does not exist to the system, and their "no" is
never written down anywhere it could be read as data about them. (Your private memory
that the conversation happened is yours; the substrate's memory is empty.)

---

*Provenance: consent classes & self-signature → HARNESS.md 2A, corpus 11 §1.2 ·
recording as separate consent → 2B structural check, runbook 0.1 · seed shown once,
never persisted → phase3a acceptance (tested) · revocation atomic incl. gate flip →
phase2A/2D acceptance (tested) · "generated on my laptop" honesty → Ops.consent_ceremony
mechanics · lost-seed hard edge → SUBSTRATE.md §8 (social recovery open) · demo
commands → mix tasks, live.*
