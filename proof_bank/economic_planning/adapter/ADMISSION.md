# Synthetic harbor source admission

The example uses four synthetic provider series. A port reports shared cargo
space, a seller and a broker quote the same delivered fuel charge, and a
research provider supplies a signed fractional policy-rate string. The sample
scenario allocates 7 of 10 kg of sea cargo space and includes one USD 300
minor-unit quote. The rate remains opaque source evidence with an unknown
kernel quantity.

## Host inputs and epoch installation

The trusted local host supplies receipt time, issue time, a provider keyring
and a complete grant set. Each provider authenticates the exact UTF-8 payload
with a domain-separated HMAC-SHA256 tag under a distinct key. The payload
includes its provider, series, revision, publication time, effective interval
and exact value or null. The host pins each series to its provider, signal
identity and units. Publication must precede or equal receipt, which must
precede or equal issue. The cargo-space and fuel series share the registered
half-open interval [20, 23).

The host registry maps the capacity to one scope, constraint and bucket across
transport modes. Both quote series map to one economic effect. The provider
cannot assign either identity. Missing series reject the entire batch. An
explicit null admits evidence with an unknown quantity and grants no capacity
or monetary total. Signed and fractional values are rejected in integral
series. The indicator preserves the original authenticated bytes in the local
revision table and carries only their commitment and a null quantity into
replay.

Installation validates all inputs and then opens a SQLite immediate
transaction. It binds every exact series and revision to its payload, tag
and receipt time, appends the validated host snapshot and appends the complete
read-grant set. A failed write rolls back the epoch and any new revisions.
Epoch numbers strictly increase and issue times cannot go backward. A grant
must match the scope and an exact source revision in the new snapshot. The
snapshot name commits the epoch number, host document and sorted grant rows.
Existing epochs are retained locally for inspection. Only the latest epoch
is eligible for replay.

Replay receives a host-asserted principal and scope independently of provider
authentication. A second immediate transaction prevents concurrent writers
from advancing the epoch between the first source check, the final source
check and certificate serialization. Replay returns the serialized certificate
after commit. A revocation committed before this transaction takes effect on
that request. If replay acquires the write reservation first, a concurrent
revocation is ordered after replay. This is a single-file local transaction
boundary. Delivery over a network and remote authorization changes would need
their own consistency contract.

The example uses public fixture keys. It demonstrates symmetric message
authentication and pins provider authority to individual series. The host can
also produce a valid tag because it holds the verification key. The trusted
boundary includes the local process, keyring, database file, registry, clock
assertions and grant writer. The example assumes a single registry and keyring
for the life of that file. External principal authentication, provider key
rotation, and independent attestation of observations remain open obligations.
The accepted output is restricted to synthetic scenario certificates. The
existing public wire schema and kernel transitions are unchanged.

## Proof and acceptance

| Obligation | Evidence |
| --- | --- |
| Every permitted read binds the current epoch and the exact principal, scope, source and revision | Lean `permits_exact` and `complete_reads_exact`, plus independent identity and stale revision cases |
| Stale epochs and removed grants deny access | Lean `stale_epoch_denies` and `revoked_grant_denies`, plus replay across a committed grant replacement |
| Provenance binds exact bytes and approved providers | Wrong key, claimed provider substitution, payload tampering, and validly authenticated same-revision replacement controls |
| Failed installation and concurrent replay preserve epoch consistency | SQLite rollback with a partial revision insert, database reopen, and a competing writer during replay |
| Resource and monetary effects retain their canonical identities | Fixed catalog binding, two-quote duplicate rejection, and renamed-effect rejection through the unchanged boundary |
| Unknown and out-of-domain values retain their meaning | Missing batch, explicit null, opaque rate, signed/fractional quantity and numeric literal controls |

The Lean proofs cover the abstract grant predicate. The executable checks cover
the concrete SQLite and Python wiring. A refinement proof connecting these
layers, a cryptographic security proof, and distributed authorization remain
outside this example.

From `proof_bank/economic_planning`, run with the repository-pinned Lean
toolchain and Python 3.12.

```sh
lean lean/Admission.lean
python3 -B -m unittest -v adapter.test_admission adapter.test_adversarial
```

The fixed fixture's certificate envelope has SHA-256
`c600031cf7e3b1c0ce5e86a5640c89c6f0048df59dd70301e343e56b74db220d`.
The hosted workflow checks the admission suite at the pull request's exact
head and uploads its log alongside the existing verification receipt.
