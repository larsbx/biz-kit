# ScfCore: Algerian accounting (Système Comptable Financier)

Pure, dependency-free double-entry accounting for Algerian entities under the
SCF: Loi 07-11 (25 Nov 2007), Décret exécutif 08-156 and the Arrêté of
26 July 2008 (nomenclature des comptes). Amounts are integer centimes (DZD).

| Module | Scope |
| --- | --- |
| `ScfCore.Chart` | Classes 1–7 headline accounts with libellés; any sub-account under a listed prefix (`41100012` ⊂ `411`) |
| `ScfCore.Entry` | Écriture: journal code, date, pièce justificative, lines; reports *every* violation, requires Σ débit = Σ crédit |
| `ScfCore.Ledger` | Immutable append-only grand livre: idempotent by id, id conflicts refused, closed periods intangible, corrections by contrepassation only; movements, balances, balance générale |
| `ScfCore.Tva` | Dated rates (19 %/9 % since LF 2017; 17 %/7 % before), HT↔TTC with exact centime rounding, G50 position from 4457 − 4456 |
| `ScfCore.Statements` | Compte de résultat par nature (production → VA → EBE → RO → RF → résultat net) and Bilan (actif/passif, courant/non courant, net of 28/29/39/49/59) |
| `ScfCore.Money` | `1 234 567,89 DA` formatting |

## Invariants (property-tested, `test/invariants_test.exs`)

For every finite sequence of admitted entries:

1. Σ débit = Σ crédit (balance générale)
2. total actif = total passif (bilan)
3. TCR résultat net = Σ₇(c − d) − Σ₆(d − c)
4. balances are invariant under permutation of postings
5. an entry followed by its contrepassation leaves balances unchanged

## Out of scope (host / later work)

Persistence and replay, multi-exercice carry-forward (à-nouveaux and
affectation du résultat), IBS/IRG/payroll (CNAS), tableau des flux de
trésorerie, annexes, the liasse fiscale and G50 forms beyond the TVA
position, and multi-currency (écarts de change). Tax rates are dated data:
add a row for each new Loi de finances, verified against the published text;
never edit a past row.

Run `mix test` from `apps/scf_core`.
