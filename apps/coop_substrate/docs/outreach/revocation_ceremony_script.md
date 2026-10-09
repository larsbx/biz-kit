# The revocation ceremony — when someone wants out

*Counterpart to `consent_ceremony_script.md`. Corpus 00: exits must be legible; 13A: the
system "makes the evidence visible, the terms declared, the exit legible." This ceremony
is the promise being kept in front of a witness — and every friendly carrier will hear
how it went. **No friction, no negotiation, no "can I ask why."** If they volunteer a
reason, write nothing down: a person who leaves does not become data on the way out.*

---

## Tone, before mechanics

The consent ceremony earned trust by working; this one earns it by *costing you
something visibly and happening anyway*. If their revocation flips `gate(D)` false, that
happens in front of them, and your face stays friendly. That is the product.

## Before they arrive (or before the call)

```
[ ] HARNESS_KEYS_DIR set; app runs
[ ] their interviewee_ref looked up (your private notes — NOT by asking them to recall)
[ ] know what's downstream of them (mix harness.status now, so nothing surprises YOU)
[ ] if remote: they can read the key over the phone or send a photo of the slip —
    never ask them to email/text the bare key if avoidable; the prompt takes it directly
```

## The ceremony

### 1 — Receive it (10 seconds, and mean it)

> "Done — let's do it right now, together, so you watch it happen. You don't owe me a
> reason, and I'm not writing one down."

### 2 — The key comes back

They bring the slip (or read it out). Run:

```
mix harness.revoke --ref IV-__          # paste/type the key at the prompt
```

*(If they typed it themselves on your keyboard, better still. Never put the key in a
shell argument; the prompt exists for this.)*

If it rejects with `wrong_key_for_role` — the transcription is off; work through the
slip's grid groups together. The rejection is the system doing its job: nobody, you
included, can revoke without the real key.

### 3 — Show it, immediately

```
mix harness.status
```

> "There it is. Your interviews, your answers, your documents — the system now treats
> all of it as if you never spoke. Nothing can count it, use it, or copy it forward.
> And you can see it took the project's numbers down with it —" *(if it did)* "— that
> was the deal."

Optional, strongest proof — try to use their material and let the machine refuse:

```
mix harness.findings --id F-x --interview I-<theirs> --kind pain --body "test"
# → REJECTED: {:no_active_consent, "IV-__"}
```

> "That's me, the operator, being told no. It'll say no to me forever."

### 4 — The precise truth about the ledger (say it unprompted)

> "One thing I want to be exact about, because I was exact at the start: this system's
> record book can't be edited — by anyone, ever. That's the property that stopped me
> from faking your consent, and it means the entry where you originally spoke isn't
> shredded; it's sealed. Sealed means: no use, no counting, no copying forward, and it
> was never public to begin with — it sits in the co-op's records the way a crossed-out
> line sits in a paper ledger. What I *can* physically destroy, I will, today: the
> recordings and document copies you gave me. That's my next hour."

### 5 — What still stands for them

> "Three things don't change. If we agreed an honorarium, you're still owed it —
> participation happened. Your paper's spent — the key has nothing left to sign — keep
> it or burn it, your call. And the door isn't closed: if you ever want back in, we
> start fresh, new key, new choices — this one's decision doesn't follow you."

*(True: revocation is terminal per ref; return = new ref + fresh consent — 2A flagged
policy. And: no more membership follow-up calls — that permission died with the rest.
Say that too if prospect_record was among their grants.)*

### 6 — Close

> "Thanks for the hour you gave, and for testing whether the exit works. It does."

## Founder follow-through — same day, non-optional (this IS the ceremony's second half)

```
[ ] delete their raw artifacts from the artifact store: every DocumentCollected /
    recording hash sourced from their interviews (hash-referenced out-of-log storage
    exists exactly so this erasure breaks nothing — SUBSTRATE.md §7)
[ ] recompile + republish the process model (mix harness.model publish) — the new
    compilation drops them automatically; the OLD artifact is now provably stale
    (recompile-and-compare) — stop distributing it
[ ] if fixtures cited their interviews: republish the set without them (a new
    publication citing them would be gate-rejected anyway)
[ ] if the spec was already ADOPTED on evidence that included them: recompile; if the
    model changed, re-adopt against the new hash before any further build step —
    a governance duty, not a mechanism (the old adoption event stands as history)
[ ] their names/lanes STAY on the denylist forever — redaction outlives participation
[ ] mix harness.status — read the honest new numbers; if the gate flipped, the answer
    is more interviews, never less rigor
[ ] no note anywhere about why they left
```

---

*Provenance: atomic computed exclusion + gate flip → 2A/2D acceptance (tested) ·
append-rejection of post-revocation use → `{:no_active_consent, _}` gate check (tested) ·
"sealed, not shredded" → SUBSTRATE.md §1 append-only + §7 (referenced-not-embedded;
erasure outside the log breaks nothing) · bilateral non-publication → disclosure classes
(07 §5) · terminal-per-ref, fresh return → phase2a plan (flagged policy) · honorarium
survives → HonorariumAccrued gate (consent record, active or not) · stale-model
detectability → 2C byte-identical recompilation (tested) · adoption re-binding →
SpecAdopted model_hash gate (tested).*
