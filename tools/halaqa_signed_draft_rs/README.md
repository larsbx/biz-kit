# Offline Rust signed-draft conformance

Private test executable only. The verifier has no networking, Iroh/Port,
persistence, admission or effect API. Success means
`SIGNATURE_VALID_AUTHORITY_UNVERIFIED`; authority and production-receiver flags
remain false. It runs only the compiled source-pinned corpus and rejects command
arguments. No caller-selected candidate, policy or corpus can activate it.

Source: Halaqa `7f677f7f82bd9c2d8f020996dc5352bc59a364af`, signed draft-2.
The fixed SHA-256 anchor is
`52d3450403e0c26cee4bfa2c86b5431fe3bc8d8488d15fafee2ecd75d6f8b4bd`.
The default runner checks that anchor and the exact 8/66 counts before producing
a conformance summary. A repin requires explicit review of the source and anchor.
Existing Python pin validation additionally checks all source/blob hashes.

The decoder bounds signed wire, candidate, payload, depth, identifiers and parent
sets. Fixed-size public-key/signature encodings are length-checked before decoding.
It refuses duplicate keys, bool/float timestamps and noncanonical base64. Serde
raw values preserve integer lexical semantics: `-0` is integer zero; `-0.0` and
`0e0` remain floating values and fail integer checks. Oversized numbers become
invalid typed values, so exponent overflow is refused in its numeric field.
Parsing never replaces or reserializes the original signed candidate bytes.

Ed25519 uses Dalek's independent Rust primitive with strict verification and
canonical point/small-order checks. External TEST policy binds key, sender,
recipient, circle, charter, epoch, clock and revocation flag. These fixture inputs
prove no real identity succession, revocation freshness or governance authority.

## Reproduce

Run from the repository root. CI selects Rust 1.99.1; the conflict-resolution tree was verified locally
with that exact toolchain. Earlier results also passed on Rust 1.93.1. The existing package minimum remains Rust 1.85; that
minimum was not separately tested.

```sh
cargo fetch --locked --manifest-path tools/halaqa_signed_draft_rs/Cargo.toml
cargo fmt --manifest-path tools/halaqa_signed_draft_rs/Cargo.toml -- --check
cargo clippy --locked --offline --manifest-path tools/halaqa_signed_draft_rs/Cargo.toml --all-targets -- -D warnings
cargo test --locked --offline --manifest-path tools/halaqa_signed_draft_rs/Cargo.toml
cargo run --locked --offline --manifest-path tools/halaqa_signed_draft_rs/Cargo.toml
python3 tools/check_halaqa_rust_differential.py
python3 tools/check_halaqa_federation_draft.py
python3 -m unittest discover -s tools -p test_halaqa_federation_draft.py -v
elixir tools/check_halaqa_signed_draft.exs
elixir tools/test_halaqa_signed_draft.exs
```

Nineteen Rust tests cover all 74 signed cases with exact verified bytes/refusal
reasons and fresh independent signatures/transcripts. Added controls exercise
changed payload bytes with recomputed digest, changed signatures/keys, signed
wrong actor/recipient/circle/charter/epoch, revoked TEST keys, half-open expiry,
encoding/size/depth limits, numeric lexemes, source tampering and remote authority
flags. Repeated verification remains stateless and commits no replay ID.

The execution receipt hashes the actual tested inputs and records command
output. The merge-resolution receipt `evidence-2026-11-01-merge.json` records the
reconciled workflow and Rust 1.99.1 results. Hosted workflow artifacts
separately retain the exact head, tool
versions, tests, conformance and diagnostic JSON. Local evidence is not a claim
that hosted CI passed or production contracts were approved.

## Diagnostics and profile history

The initial draft-1 experiment at Halaqa `11eb6309ec6caccb6aab3c821eba2311881c9ba0`
had 48 matching signed cases, but OpenSSL and OTP accepted a synthetic identity
public key/R with zero S which Rust strict verification refused. The original
implementation/evidence is retained in [PR #228](https://github.com/larsbx/biz-kit/pull/228).
Draft-2 changes the schema/domain and explicitly refuses weak/noncanonical
encodings. The current 74-case checks demonstrate the correction; no draft-1 or
unsigned fallback is added.

| Fixed extra probe | Python/OpenSSL draft-2 | Rust draft-2 |
| --- | --- | --- |
| Identity TEST key and identity R, zero S | `invalid_signature` | Same |
| Lone-surrogate sender (`\ud800`) | `identifier` | `invalid_json` |
| Integer `-0` epoch | Format only, unverified | Same |
| Overflowing exponent epoch (`1e400`) | `epoch` | Same |

The lone-surrogate diagnostic is refused by both parsers; one of the 40 unsigned
exact refusal reasons differs. It is recorded separately from the 74 signed
cases and does not count as conformance. The external Python/Rust comparison
fails on a changed or new difference. No Python or OpenSSL code implements Rust
verification itself. This finite corpus establishes neither full parser/crypto
equivalence nor production F2 acceptance. Production signing, identity,
revocation/governance, replay, domain admission and direct/relay Iroh remain
separately gated. No business writer or live Iroh ingress is added.
