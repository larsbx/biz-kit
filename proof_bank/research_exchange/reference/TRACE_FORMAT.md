# Executable trace protocol (v1)

The Python reference codec and Lean executable use the following replay format.
The Lean executable consumes one JSON object per input line and emits one JSON
object per output line. Each input describes a complete pure replay.
No transport server, authentication, proof checking, metering, or persistence is
provided here. Equality of finite executable traces is a test, not a refinement proof.

Request shape:

```json
{"kind":"reward","config":{"expected":{"target":1,"input":2,"environment":3,"policy":4},"reward":5,"workerA":10,"workerB":20},"state":{"now":0,"generation":0,"owner":10,"expires":0,"phase":"open","candidate":null,"payouts":0,"funder":7,"escrow":5,"balanceA":0,"balanceB":0},"actions":[{"type":"lease","worker":10,"deadline":2}]}
```

```json
{"kind":"reservation","state":{"phase":"idle","available":10,"held":0,"spent":0},"actions":[{"type":"reserve","cap":5},{"type":"start"},{"type":"cancel"},{"type":"stop","trusted":true},{"type":"settle","cost":3}]}
```

Response: `{"states":[<initial state>,<state after action 1>,...]}`. All state fields
are returned. Rejected well-typed actions leave the state unchanged. Naturals use
JSON integer numbers (including values larger than 64 bits), never strings,
booleans, fractions, or negatives. `trusted` uses a JSON Boolean.

Reward actions are `tick(delta)`, `lease(worker,deadline)`,
`submit(worker,generation,binding,artifact)`, and `accept(trusted,evidence)`.
Each action uses a `type` discriminant and only the listed arguments. A binding is
`{target,input,environment,policy}`. A candidate/evidence is
`{worker,generation,binding,artifact,submittedAt,leaseExpires}`.

Reservation actions are `reserve(cap)`, `start`, `cancel`, `stop(trusted)`, and
`settle(cost)`.

The supplied initial state permits single-step boundary comparisons outside the
reachable-state set. Such tests assess implementation agreement only. Reachable
traces are separately labelled in corpus metadata; Lean's safety theorems apply
with their stated initial-state and configuration hypotheses. Distinct workers are
a prerequisite for commissioned reward configuration.

Python CLI: `python -m reference.conformance --emit-corpus corpus.jsonl`.
Differential CLI:
`python -m reference.conformance --lean-command '<command>' --report conformance.json`.
The Lean command must accept the JSONL protocol on stdin and produce JSONL only
on stdout (diagnostics belong on stderr). It is invoked once for the whole corpus.

The Python decoder rejects missing or extra fields, duplicate object keys,
negative numbers, fractions, booleans in numeric positions, numeric strings,
non-JSON constants, unknown action types, and unknown phases. Trust decisions have
no default: both `accept` and `stop` require an explicit Boolean `trusted` field.
This is a local testing interface. A caller setting that field to `true` does not
constitute authentication, artifact verification, or authority to receive payment.

`CONFORMANCE_PASSED` is printed only after the subprocess exits successfully and
every output line and complete state agrees. Empty, extra, truncated, malformed,
mistyped, or different outputs fail the comparison. The report records the input
and output hashes, trace and state counts, and explicit finite-test scope.
