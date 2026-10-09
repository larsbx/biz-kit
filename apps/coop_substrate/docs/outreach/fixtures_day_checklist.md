# Fixtures day — the anonymization session

*Runbook Phase 6, the half synthesis day deferred. A fresh session, because the
machinery catches what regexes can catch (MC/DOT, emails, phones — it fails closed and
names the violation) and the **denylist is where your judgment does the rest**. The
predicate is a floor, not a proof (2B, flagged); today your eyes are the ceiling.
These fixtures become the dispatch tool's TDD corpus (11 §1.5) — the payoff for doing
this carefully is that the parser gets tested against reality instead of imagination.*

---

## 0 — Preconditions

```
[ ] adoption done (synthesis day closed) — fixtures are the named short leg in status
[ ] you are rested; this is the session we deliberately didn't do tired
[ ] consent audit: list the interviews whose consent includes anonymized_fixtures —
    ONLY these may be sources (the gate rejects others, but know your list first);
    any revoked interviewee is already off it automatically
[ ] denylist harvests from EVERY capture day consolidated into one denylist.txt
    (private dir — the notes template had you harvesting at writing time; today
    you merge)
```

## 1 — Staging hygiene (the sharp edge: publish reads EVERY file in the dir)

```
[ ] make a CLEAN staging dir (e.g. private_dir/fixtures_staging/) — empty
[ ] never copy a raw, unredacted document into it, even "for a second" —
    redaction happens on the way in, file by file
[ ] the denylist file stays OUTSIDE the staging dir (it's passed by path and never
    enters the artifact; a denylist accidentally in the dir would publish the
    sensitive list itself — the exact inversion of the point)
```

## 2 — Building the fixture files (from your private-dir document copies)

```
[ ] text only: the predicate scans text and FAILS CLOSED on binaries — PDFs and
    photos must become text extracts first (the artifact store keeps the originals;
    the fixture is the parser-facing text)
[ ] keep the FORMAT quirks: broken columns, ALL-CAPS blocks, the weird abbreviations —
    real rate cons in the wild's actual formats are the entire value (11 §1.5);
    anonymize the identities, never the mess
[ ] replace, don't delete: [CARRIER], [BROKER], [MC], [CITY-A]→[CITY-B], [RATE] —
    a parser fixture with holes shaped like the data teaches more than one scrubbed
    smooth
[ ] fold fixtures too: timeline files from the duration findings ("invoice paid in
    N days" patterns — values may stay; they're already detached from anyone)
[ ] one more read of EACH file, start to finish, hunting what regexes can't know:
    nicknames, facility names, "the yard on [road]" — every catch goes in the
    denylist AND the file
```

## 3 — Publish (the failure is the scanner working)

```
[ ] mix harness.fixtures publish <staging_dir> --denylist <path> --sources I-_,I-_
[ ] a REJECTED naming a file + violations is the predicate doing its job: fix that
    file (and denylist if it was a literal), run again — one violation kills the
    whole set BY DESIGN; nothing partial ever publishes
[ ] clean run → record the fixture_hash: ____________
[ ] paranoia pass (cheap, worth it): fetch the artifact back and read the bundle
    once more as a stranger would — it's commons-classed content now
```

## 4 — Close the day

```
[ ] mix harness.status — the fixtures leg closes; if gate=true, STOP and feel it,
    then treat BuildStarted as its own deliberate moment (runbook phase 7) — not a
    tired evening's reflex; tomorrow morning works
[ ] mix harness.checkpoint → publish off-machine (the gate's truth is now committed
    history)
[ ] weekly status milestone line; staging dir deleted (originals live in the private
    dir and the artifact store; the staging copy has no reason to exist)
```

---

*Provenance: predicate mechanics + fail-closed non-text + denylist-never-in-artifact →
2D machinery (tested) · whole-set-fails → Fixtures.publish (tested) · source consent →
FixtureSetPublished gate (2A, tested) · format-quirks-are-the-value → corpus 11 §1.5 ·
predicate-as-floor → 2B/2D flagged limits · gate=true → BuildStarted as deliberate →
runbook phase 7, D-build brief gate-in.*
