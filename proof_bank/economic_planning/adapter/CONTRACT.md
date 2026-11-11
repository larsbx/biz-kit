# Offline replay boundary, version 1

This is the first executable portion of EPV-02. It is an offline Python
standard-library reference adapter for the research toolchain. No provider,
application service, database, identity provider or business writer is connected.
Platform authentication and a durable atomic source/grant snapshot remain a
later integration gate. The existing application runtime is unchanged.

## Separate authority from requests

`FrozenSnapshot` is constructed by the host from strictly validated bytes. Its
schema is `biz-kit/economic-planning/host-snapshot-v1`; its exact fields are
`schema`, `scope`, `issuedAt`, `snapshot`, `models`, `operationalToken`, `sources`,
`resources` and `costComponents`. Sources are complete kernel `Evidence` records. Resources are
`{key: ResourceKey, value: Resource}` entries. Duplicate structured source and
resource identities are refused, including equal duplicate records. Records
must belong to the snapshot scope, and each catalog resource must agree with
its source's full physical signal and optional quantity. Models are an exact
nonempty allowlist of host-approved model identifiers.

`costComponents` binds each exact monetary source total to its canonical ordered
component list: `{source: SourceRef, components: [String]}`. Source references are
distinct and components are nonempty and distinct within a binding. A submitted
cost line must exactly match that host binding before any certificate is released.
Separate quotes/reports of the same effect must share host-assigned components;
callers cannot bypass deduplication by renaming them. Constructing the canonical
effect registry still belongs to the host. The catalog binding is checked after
authorized replay and before release, so a guessed private quote cannot be used
to probe its component identities.

`HostIdentity(principal, scope)` comes from the host. The injected read authorizer
receives that identity, the exact snapshot revision, and the exact source
reference. Only the Boolean value `True` grants access; errors deny access.
Every requested source is checked before preparation and again before returning
a certificate. The injected callback is an authority contract, not an implemented
authentication system. The future host must make the final check and response
release consistent with its grant epoch; this process cannot atomically commit
against a remote authorization system.

The caller supplies only a UTF-8 request with schema
`biz-kit/economic-planning/request-v1` and exact fields `schema`, `snapshot`,
`model`, `scenario`, `seed`, `horizonStart`, `horizonEnd`, `currency`, `actions`.
Authoritative manifest scope, issue time, source records, read permissions,
resource catalog and initial operational token come from the host. The request cannot contain a prior state,
certificate, source payload, authority flag or executable command.

Actions use one of these exact shapes:

| Kind | Additional fields |
| --- | --- |
| `evidence` | `expectedRef`, `expectedKey`; the host supplies the actual record |
| `allocate` | `allocation`, with the kernel's exact `Allocation` fields |
| `cost` | `line`, with the kernel's exact `CostLine` fields |
| `publish` | `claim` |

The public request contains exactly one publication and it is the final action.
A failed action rejects the whole request and releases no partial certificate.
The internal verification oracle accepts arbitrary action sequences to exercise
all kernel transitions, including preservation of earlier publications.

## Exact wire representation

All fields retain the camelCase spelling in `EconomicPlanning.lean`. Enum
values retain their constructor spelling. All modeled natural numbers are
**JSON strings** in canonical ASCII decimal notation: `0`, or a nonzero digit
followed by digits, at most `9223372036854775807`. No sign, whitespace, leading
zero, decimal point or exponent is accepted. Numeric JSON literals are refused.
Optional quantities and maturities use explicit `null`; missing fields are
errors. This bounded wire subset embeds exactly into Lean's unbounded `Nat`.

Time fields and resource bucket labels use host-normalized UTC Unix seconds.
The host must supply one consistent atomic bucket partition; this boundary does
not infer interval overlap or create additional capacity dimensions. Units,
material, purity/grade, form, currency, place and instrument are exact identities.
There is no unit, FX, purity or price-to-total conversion. Money uses
`moneyMinorUnits`, unit `minor-unit`, and a three-letter uppercase currency.
Other currency fields may be empty. Physical units are explicit nonempty strings;
their physical validity remains a source/catalog obligation.

The current kernel represents nonnegative integral quantities and monetary
totals. Signed or fractional market observations, including negative prices and
rates, need a later explicit numeric adapter. They may currently appear as
source-bound indicator metadata with `quantity: null`, without pretending that
their numerical value was interpreted. Never clamp, round, take an absolute
value or silently change a unit to make such a value fit this schema.

Source payload digests must be 64 lowercase hexadecimal characters. They remain
host assertions about provider payloads; the adapter does not retrieve those
payloads. It separately computes domain-separated SHA-256 commitments over the
actual request bytes, the canonical validated snapshot and the replay bundle.
These hashes are neither signatures nor provider-authentication evidence.

Inputs reject unknown keys, duplicate decoded object keys, invalid UTF-8 or
Unicode surrogate scalars, control characters, floating-point values, NaN,
Infinity, excessive nesting, and unsupported enums. There is no Unicode
normalization or case folding. Structured tuple identity avoids delimiter
collisions. Request size is 256 KiB; host snapshots are at most 1 MiB;
nesting is at most 24; decoded nodes at most 50,000; each string is
at most 512 UTF-8 bytes. There are at most 256 actions, 128 sources, 256 catalog
entries and 64 cost components. Prepared replay bytes are capped at 2 MiB before
execution. These are execution bounds, not business capacity.

## Differential oracle

The test-only Lean JSONL oracle receives an internally prepared bundle:
`{manifest, sources, readable, resources, operationalToken, actions}`. Its
evidence actions contain `{kind, request: {expectedRef, expectedKey, evidence}}`.
The other action shapes match the public request. `readable` is a list of exact
source references generated by the host boundary, never accepted from callers.

Both the Python reducer and Lean oracle produce
`{accepted, rejectedAt, states}`. `states` begins with the initial state and
contains a complete value snapshot after every accepted action. Rejection stops
at the first action; `rejectedAt` is its zero-based index or `null` for success.
All natural values in oracle output also use decimal strings. The oracle uses
the actual kernel transitions. Its parser and executable bridge are trusted test
infrastructure, not a bounded public input or authorization boundary. The public
and host byte/depth/collection limits above belong to the Python boundary;
the Lean oracle receives only the committed deterministic fixture corpus.

Successful Lean replay is proved to imply an accepted trace from `initial`.
Independent proposition contracts and namespace axiom auditing apply to those
proofs. Full-value differential comparisons and deliberately broken candidate
implementations exercise the internal reducer on prepared bundles. Independent
golden/adversarial tests exercise public decoding, host preparation, authorization
and exact output certificates. These are separate evidence classes. This
is finite executable evidence, not a universal Python/Lean refinement proof,
source-truth guarantee, forecast evaluation or deployment result.
