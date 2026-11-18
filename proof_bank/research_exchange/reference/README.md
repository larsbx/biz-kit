# Executable reference and differential checks

This directory implements the two sequential kernels in
`formal/lean/MODEL_CONTRACT.md`: one prefunded reward slot and one quota
reservation. It is an independent Python reference for comparison with the Lean
implementation. It is not extracted from Lean, and no refinement theorem links
the Python implementation to Lean.

Run the adversarial suite from the repository root:

```sh
python -m unittest discover -s tests -v
```

After building `exchange_trace`, run the actual executable comparison:

```sh
python -m reference.conformance \
  --lean-command formal/lean/.lake/build/bin/exchange_trace \
  --report conformance.json
```

The current deterministic corpus contains 1,898 traces and 1,958 actions. It
compares all 3,856 states, including the initial state of each trace. Nine traces
start from commissioned initial states and exercise longer action sequences;
1,889 explicitly supplied guard probes may use unreachable states. Those probes
check agreement on transition guards and do not establish reachability. The
corpus includes integers larger than 64 bits.

The 29 unit tests cover exact target/input/environment/policy binding, every
candidate field in verdict evidence, stale generations, the exclusive lease
deadline, allowed worker identities, verifier delay after timely submission,
immutable values, payment retries, insufficient escrow, reservation caps,
cancellation before and after start, confirmed stop, partial refunds, zero and
full settlement, and credit conservation. Two manually authored serialized
fixtures supply expected complete states independently of the Python transition
implementation. Five deliberate faulty transition functions demonstrate that the
tests detect weakened binding, evidence substitution, an expiry recheck at
verification, a reopened payout slot, and a premature cancellation refund.

`codec.py` validates the serialized input domain before invoking the kernel. The
dataclasses in `kernel.py` are typed model values; constructing them directly
bypasses JSON validation. Identifiers are abstract natural numbers representing
commitments, not computed cryptographic digests. The commissioned reward model
assumes two distinct worker identities.

## Trust boundary

`trusted` is an explicit assumption in this local model. The parser requires a
Boolean, but it does not authenticate a verifier, inspect a proof artifact, or
confirm that a sandbox process stopped. The trace runner must not be exposed as a
public verification authority. Public actions will need adapters that derive
trusted evidence through authenticated internal verifier and supervisor paths.

There is no HTTP/MCP/UTCP server, database, real compute metering, sandbox, global
ledger, concurrent transaction implementation, or artifact verifier here.
Successful differential tests establish agreement only for the finite supplied
traces. The Lean theorems establish the properties stated in the formal model;
neither result proves a later deployment correct or establishes liveness.
