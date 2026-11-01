# Independent offline Halaqa signed verifier

Test tool only; private executable, no exported library, network listener, Iroh,
Port command, persistence, authorization token, BuzzBridge or business writer.
Successful verification yields only `SIGNATURE_VALID_AUTHORITY_UNVERIFIED` plus
original payload and reconstructed transcript bytes internally. The runner's
authority and production-receiver flags are always false. It accepts no input
arguments or stdin and runs only the compiled, source-pinned synthetic corpus.

The input contract is Halaqa PR #9 at
`11eb6309ec6caccb6aab3c821eba2311881c9ba0`. The 48 signed vectors remain unchanged:
SHA-256 `03d87ac6cbb664135b7fd03a9450355b01fb42c1f486f1c8e76764795b15ac04`.
The corpus digest is checked against a fixed anchor before any case is examined;
`source-pin.json` and the Python pin checker retain upstream source/blob evidence.
Repinning requires review of both the upstream bytes and the anchor.

The implementation uses serde's raw values and an independent duplicate-key
visitor, canonical padded base64, SHA-256 and `ed25519-dalek` 2.2.0
`verify_strict`. No Python, OpenSSL, Elixir or sidecar call implements Rust
verification. All dependencies are locked. No legacy-compatibility Ed25519
feature, prehash or batch verifier is used.

Decoding caps signed frames at 12,288 bytes, candidates at 8,192, payloads at
4,096, nesting at 8, identifiers at 128 and parents at 16. Fixed-size key and
signature encodings are length-checked before allocation. Each candidate retains
its original wire bytes: the signing transcript is the NUL-terminated domain,
u32be key length, key bytes, u64be issue/expiry seconds, u32be candidate length
and original candidate bytes. No reserialization or normalization enters it.
Raw numeric lexemes distinguish integer `-0` from floating `-0.0`/`0e0`;
out-of-range numbers remain invalid typed values. Policy pins, revocation flag
and clock are external TEST assertions and cannot be supplied by the frame.

## Reproduce

Use Rust 1.93.1, Python 3.10+ and an Ed25519-capable OpenSSL reference backend.
Fetch dependencies once, then all verification/check commands work offline:

```sh
cargo +1.93.1 fetch --locked --manifest-path tools/halaqa_signed_rust/Cargo.toml
cargo +1.93.1 fmt --manifest-path tools/halaqa_signed_rust/Cargo.toml -- --check
cargo +1.93.1 clippy --locked --offline --manifest-path tools/halaqa_signed_rust/Cargo.toml --all-targets -- -D warnings
cargo +1.93.1 test --locked --offline --manifest-path tools/halaqa_signed_rust/Cargo.toml
cargo +1.93.1 run --locked --offline --manifest-path tools/halaqa_signed_rust/Cargo.toml
python3 tools/check_halaqa_federation_draft.py
python3 -m unittest discover -s tools -p test_halaqa_federation_draft.py -v
# Select 1.93.1 in PATH for the diagnostic runner's cargo subprocess:
rustup override set 1.93.1
python3 tools/check_halaqa_rust_differential.py
elixir tools/check_halaqa_signed_draft.exs
elixir tools/test_halaqa_signed_draft.exs
```

The 15 Rust tests check all 48 exact signed verdicts/reasons and all eight
payload/transcript pairs, fresh independently assembled signing transcripts,
recomputed payload digests with stale signatures, signature/key substitution,
signed wrong actor/recipient/circle/charter/epoch, revoked TEST pins, boundary
expiry, malformed/oversized encodings, duplicate keys, numeric lexemes and remote
authority flags. Repeated verification remains stateless; it consumes no replay ID.

## Demonstrated disagreements beyond the signed corpus

All three runtimes agree on the pinned 48 cases. That does **not** establish
unrestricted equivalence or complete F2/production acceptance.

| Probe | Pinned Python/OpenSSL | Rust strict verifier |
| --- | --- | --- |
| TEST public key = identity point; R = identity point; S = zero | Signature valid, authority unverified | `invalid_signature` |
| Lone surrogate in sender (`\ud800`) | `identifier` | `invalid_json` |
| Integer negative zero epoch | Format only, unverified | Same |
| Overflowing exponent epoch (`1e400`) | `epoch` | Same |

The weak-key signature needs no secret: raw public key = `01` followed by 31
zero bytes, signature = `01` followed by 63 zero bytes. OTP 27 `:crypto` also
accepts it in the existing Elixir test verifier. Rust deliberately keeps Dalek's
strict small-order rejection. This is a TEST-key validation gap in the reference
profile; it is not evidence of forgery under the corpus's ordinary public keys
or a live business-authority bypass. Owner review must settle key enrollment,
small-order point rejection, canonical scalar/point acceptance and exact refusal
semantics before production adoption. Do not relax Rust to match this behavior.

The lone-surrogate frame is already refused by both runtimes in the unsigned
corpus: 39 of 40 unsigned reasons match exactly; one differs as shown. Rust does
not claim complete unsigned exact-reason conformance. The separate differential
runner explicitly reports these known differences and fails on changed/new ones;
it never counts them as successful signed-corpus conformance. The original
reference source and fixtures are unchanged.

Evidence is in [the execution receipt](evidence-2026-11-01.json). Hosted workflow
artifacts capture the exact PR head, tool versions, tests, conformance and probe
output separately. The receipt is local execution evidence, not hosted acceptance,
authority, production profile approval or a formal proof of the implementation.

Production signing/identity/revocation/governance approval, durable replay,
domain admission and direct/relay delivery remain separate gates. No live Iroh
ingress or new business writer is activated by this crate.

API references: [Dalek 2.2.0](https://docs.rs/ed25519-dalek/2.2.0/ed25519_dalek/),
[Dalek validation criteria](https://github.com/dalek-cryptography/curve25519-dalek/tree/ed25519-2.2.0/ed25519-dalek),
[serde raw values](https://docs.rs/serde_json/1.0.145/serde_json/value/struct.RawValue.html).
