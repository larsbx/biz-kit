# Remaining dependency security correction (issue #157)

The baseline is Bandit correction `6d4d67b42858a7c88bdd2569ae0cbb588f8d9461`.
Its full shared-lock audit reported 13 advisories. This correction upgrades the
three affected **active** packages, upgrades AshSQL as required by AshPostgres,
and removes the unused req_llm lock entry. Bandit stays at 1.14.0.

| Package | Baseline | Corrected lock | Reason |
| --- | --- | --- | --- |
| ash | 3.35.0 | 3.37.2 | Fixed primary-key tenant upserts and limited through loads |
| ash_postgres | 2.15.1 | 2.15.2 | Fixed tenant scope on joins and skipped upsert rereads |
| ash_sql | 0.8.3 | 0.8.4 | Required minimum for AshPostgres 2.15.2 |
| jose | 1.11.12 | 1.11.13 | First fixed release for all eight reported JOSE findings |
| req_llm | 1.17.1, unused | Removed, not activated | Absent from dev/test/prod dependency graphs and application code |

Every other lock entry is preserved. Eatsbot, EatsbotCore and the Telegram
extension now require Ash `~> 3.37.2` and AshPostgres `~> 2.15.2`; their former
Ash patch constraint excluded the fix. There is no Kafka, Phoenix, AshAI or
other unrelated dependency upgrade in this correction.

## Advisory and first fixed version ledger

Primary sources inspected on 2026-10-27:
[Hex Ash](https://hex.pm/packages/ash/advisories),
[Hex AshPostgres](https://hex.pm/packages/ash_postgres/advisories),
[Hex JOSE](https://hex.pm/packages/jose/advisories),
[Hex req_llm](https://hex.pm/packages/req_llm/advisories).

| Advisory | Package / affected range | First fixed |
| --- | --- | --- |
| GHSA-g2h4-xp57-q863 | ash >=3.24.0, <3.37.1 | 3.37.1 |
| GHSA-vw7c-67pf-gh96 | ash >=1.22.0, <3.37.2 | 3.37.2 |
| GHSA-gr2r-f49c-9gm2 | ash_postgres >=0.38.0, <2.15.2 | 2.15.2 |
| GHSA-36hg-wwp2-fg8w | ash_postgres >=2.6.22, <2.15.2 | 2.15.2 |
| GHSA-6gxw-6f7r-cjr6 | jose >=1.2.0, <1.11.13 | 1.11.13 |
| GHSA-vwvr-f994-6j9j | jose >=1.3.0, <1.11.13 | 1.11.13 |
| GHSA-wfpv-qxp8-x5gm | jose >=1.0.0, <1.11.13 | 1.11.13 |
| GHSA-fpj2-9h59-32pp | jose >=1.5.0, <1.11.13 | 1.11.13 |
| GHSA-h4gx-8jq2-mfhc | jose >=1.10.0, <1.11.13 | 1.11.13 |
| GHSA-xvr2-gggj-h2pp | jose >=1.10.0, <1.11.13 | 1.11.13 |
| GHSA-3m45-vrpj-xmrq | jose >=1.7.7, <1.11.13 | 1.11.13 |
| GHSA-44hw-rpw9-mwg4 | jose >=1.0.0, <1.11.13 | 1.11.13 |
| GHSA-6vww-5m28-f26v | req_llm >=1.9.0, <1.29.0 | 1.29.0 |

## Exposure and boundaries

Dispatch uses attribute multitenancy on accounts, roles, devices, operations,
audit and fleet resources; role provisioning uses upserts. These dependency
fixes matter even when endpoint authentication is correct. Dispatch also imports
JOSE for issuer JWKS parsing and strict RS256 OIDC verification. Its configured
issuer/audience, algorithm restrictions, key refresh controls, tenant checks and
application authorization remain unchanged. No seller-home ledger or federation
publication authority is widened.

req_llm is an optional AshAI integration, not selected by this umbrella. The
baseline `mix deps` graph contains no req_llm in **dev, test or prod**; no
application source calls ReqLLM, and no ReqLLM application is built. Only its
stale lock record is removed, without activating a new LLM client or deleting
other unused lock entries. This does not claim a deployed instance was inspected
or that an incident did or did not occur. If the optional integration is later
activated, require req_llm >=1.29.0 and rerun real untrusted-CA/hostname refusal
checks before sending credentials over its WebSocket path. The full-lock audit
will reject reintroducing an affected version.

The current JOSE call path is RS256 OIDC; the new primitive tests additionally
exercise full AES-GCM authentication tags and exact ECDSA signature lengths.
They do not claim exhaustive independent reproduction of all eight JOSE issues.

## Gates and acceptance evidence

The **complete shared-lock** Hex audit is now a blocking CI step. Its SARIF is
still uploaded on failure. There are no ignored advisory IDs or informational
failure allowance. The former Decimal exception is removed from the governed
audit allowlist: it expired on 2026-10-08 and Decimal 3.2.0 is already outside
both published affected ranges. No acceptance expiry is extended. The governed
Hex 2.5.1 report/parser contract is preserved.

Required validation: locked resolution without mutation; clean complete-lock
audit; strict umbrella compilation; Dispatch/PostgreSQL integration and OIDC
checks; Eatsbot authentication/tenant tests; signed two-node HTTPS/adversarial
HTTP acceptance; production smoke; existing release, model, browser and
cross-repository client workflows. Exact accepted head, final checks and merge
commit are recorded in the introducing PR and issue #157.

The new PostgreSQL cases use transaction-local `pg_temp` tables and the actual
AshPostgres data layer. They cover cross-tenant primary-key upsert takeover,
single/bulk skipped-upsert scope, tenant-filtered many-to-many joins and a
limited through load with a deliberately unrelated target. They require the
existing PostGIS integration lane; compile-only or ETS results are not treated
as SQL acceptance. No production table or migration is added.

## Dependabot #145

At head `773716e173c6bea59393f998edd7cebf14a0c1ea`, hosted compilation fails because
KafkaEx 1.1.2 removed `KafkaEx.Protocol.Produce.Message`, used by
`Eatsbot.Extensions.Kafka.Driver`. That broader PR remains separate and must
preserve this security correction when refreshed. Its Kafka migration requires
its own behavior and acceptance work; a resolver success is not a compile pass.

A clean package audit and bounded regression suite do not prove the absence of
all vulnerabilities or authorize public deployment. The explicitly peered
federation pilot and its authority restrictions remain unchanged.
