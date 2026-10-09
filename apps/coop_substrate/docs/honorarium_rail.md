# The honorarium payout rail (design note + record of scope)

> **Status: COMPLETE** (2026-07-11, single-unit build). Why machinery and not a
> spreadsheet: the corpus forbids manually-maintained balances — derived state only
> (PROJECT_INSTRUCTIONS cross-cutting disciplines). The tracker IS a fold.

## Design

```
accrue   HonorariumAccrued{interviewee_ref, amount_minor}      — existed (2A); now folded
clear    CharterConstantDeclared{"honorarium/payout_cleared", 1, note: counsel ref}
         — counsel clearance as a declared constant (zero new governance types);
         latest declaration wins, so declaring 0 STOPS payouts again
pay      HonorariumPaid{interviewee_ref, amount_minor, note?}  — an ATTESTATION of
         external settlement (the RedemptionPaid / obligation-discharge pattern;
         money never moves on-platform, 05 P11)
gate     paid ⇐ cleared == 1 ∧ accrued entry exists ∧ amount > 0
         ∧ paid + amount ≤ accrued (over-attestation unrepresentable)
tracker  Harness.honoraria/2 → per interviewee: accrued/paid/outstanding — a pure fold,
         :bilateral-classed (interviewee-keyed money trail)
CLI      mix harness.honorarium accrue|paid|list|clear   (subcommands replace the old
         flag-only accrue interface — breaking, pre-field-use, noted)
```

Honoraria accrue regardless of consent revocation (participation happened — the 2A gate
already says so) and pay out the same way; the clearance constant carries the counsel
reference in its note. [LEGAL] tax treatment of amounts remains counsel's question; this
rail only makes the bookkeeping derived and the over/early-payment unrepresentable.

## Acceptance (tested in `test/honorarium_test.exs`)

Payout before clearance unrepresentable; clearance is reversible (declare 0 ⇒ payouts
stop); over-attestation rejected at the exact boundary; payout to a never-accrued ref
rejected; outstanding = accrued − paid recomputes as a fold; accrual and payout survive
consent revocation; task subcommands smoke-tested.
