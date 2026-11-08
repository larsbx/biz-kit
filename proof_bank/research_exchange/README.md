# Formal Research Exchange — verification core and local adapter pilot

Proof-first implementation of the acceptance and accounting boundary for a collaborative Lean/Quint research service. The package contains executable Lean transition functions, theorems about those functions, finite Quint models, a pure Python reference, a local authenticated HTTP/SQLite adapter pilot, and a reproducible verification gate.

The pilot exercises a controlled verifier and an atomic local transaction with disposable fixture credits. It listens only on `127.0.0.1`, checks exact operator-approved proof exports, and is separate from Biz-kit's production identity, signed business history and financial authority. There is no public MCP/UTCP endpoint, arbitrary Internet artifact acceptance or physical compute meter. The pure model's positive authority inputs remain explicit premises; the pilot supplies them through a narrow implementation whose correspondence is tested separately.

## Implemented kernels

**Reward slot:** two eligible participant destinations, one prefunded escrow, expiring leases with generation fencing, exact candidate admission, and atomic acceptance/payout. A candidate binds target, input, environment, policy, artifact, participant, generation and admission timing. Timely admission survives later clock advancement. A paid slot cannot pay again.

**Compute reservation:** reserve an affordable cap, start execution, request cancellation, acknowledge actual stopping, then settle cost and return the unused amount. Funds remain held while execution is running or cancellation awaits acknowledgment. A settled reservation is terminal.

Invalid, well-typed actions return the original state. The adapter extends the reward lifecycle with terminal rejection. They use natural numbers; global supply, accounting across multiple slots and production persistence are outside their proof scope.

## Local authenticated adapter

The [adapter pilot](adapter_pilot/README.md) adds credential-derived worker identity, exact verifier principal/role/slot scope, current enablement and grant epochs. It stores only domain-separated token hashes. A revoke/regrant cycle invalidates an already prepared verification. Worker routes lease a slot, submit immutable bytes and read status; the separately authorized internal verifier route triggers checking of the stored candidate. No request can supply `trusted`, a verdict, an acceptance receipt, a checker profile or a payout destination.

The controlled checker accepts only the exact approved export of the reviewed trivial fixture theorem `ResearchExchange.Adapter.expected_fixture` (`forall n : Nat, n + 0 = n`). It requires actual replay by the pinned Lean kernel and `lean4lean`. A separate true arithmetic theorem supplies a valid-proof/wrong-target control. This demonstrates a precise authority boundary; it is not an arbitrary Lean-source compiler, general research validator or sandbox. Independent replay here means independent checker software on the same trusted host.

Verification snapshots the immutable candidate, profile/configuration, row version and credential epoch. Checking occurs outside the database transaction. Commit rechecks current authority and those identities, invokes the existing reward transition, and persists reward state, one unique payout or refund effect and the canonical request/response binding together. SQLite uses WAL, `synchronous=FULL`, foreign keys and `BEGIN IMMEDIATE`. Credits and numeric database columns have explicit signed-64-bit bounds; full digest commitments remain Nat values in JSON.

The adapter acceptance suite implements 27 mandatory checks using real HTTP, concurrent processes, revoked and rotated credentials, stale versions, wrong artifacts and targets, changed-content request-ID conflicts, and actual service-process exits before/after commit. A post-commit lost response must recover the same durable receipt; a pre-commit crash must leave no payout, refund or associated receipt. `tools/run_adapter_acceptance.py` refuses skipped or missing tests. These are required gates; only an exact-revision receipt establishes the observed results for a particular revision.

A definitive mismatch against the fixed approved export closes the slot, returns its full original escrow to the fixture funder and preserves the admitted candidate and prior request receipts. Checker timeouts, unavailability and inconclusive results leave the slot submitted. A replacement requires a distinct slot and an explicit fresh escrow allocation.

## Repository map

| Path | Purpose |
| --- | --- |
| `formal/lean/MODEL_CONTRACT.md` | Shared transition semantics and explicit assumptions |
| `formal/lean/ResearchExchange/` | Executable Lean kernels and their proofs |
| `formal/lean/proof_targets.json` | Nonempty registry of named proof obligations |
| `formal/lean/negative/` | Deliberately invalid proof and axiom-policy controls |
| `formal/quint/` | Finite models, scenarios and model-checking runner |
| `reference/` | Python reference and Lean/Python trace comparison |
| `adapter_pilot/` | Loopback HTTP, controlled fixed-export checking, SQLite persistence and trusted fixture preparation |
| `tests/` | Adversarial pure state-machine and serialization checks |
| `adapter_pilot/tests/` | Real HTTP/SQLite, controlled-checker and process-crash acceptance |
| `tools/run_adapter_acceptance.py` | Mandatory adapter test lane; skipped tests cannot pass |
| `tools/verify.py` | Reviewed-source gate and evidence orchestration |
| `verification.plan.json` | Required commands, evidence classes and completion criteria |
| `toolchains.lock.json` | Exact runtime distributions and download digests |
| `SOURCE_MANIFEST.json` | Canonical inventory of the reviewed source files |
| `evidence/` | Generated receipts, logs, exported proofs and counterexamples |
| `docs/VERIFICATION_BOUNDARY.md` | Proof scope, assumptions and integration obligations |

## Fast local checks

Python 3.12 or newer is sufficient for the original pure-reference and runner checks. No Python packages are required. Run these commands from the package root:

```bash
python3 -m unittest discover -s tests -p 'test_reference.py' -v
python3 -m unittest discover -s tools -p 'test_*.py' -v
```

These are tests, not the full proof verification profile. The adapter acceptance lane also requires the pinned checkers and freshly prepared fixed-export profile; the complete profile must run it without skips.

## Reproduce the complete profile

The supplied toolchain lock targets Linux x86_64. Install Python 3.12+, Node 24.22.1, npm 11.9.0, and `zstd`; a C compiler is required to build the Lean executable and only if needed the optional application-path adapter. Select npm explicitly with `npm install --global --ignore-scripts --no-audit --no-fund npm@11.9.0`, since the Node release bundles a different npm version. The download installer verifies the pinned archives and the complete installed Lean, JRE, and Quint dependency distributions. The npm lock also pins transitive dependencies. The release receipt records the Python and Node executable identities used for the actual run; these host runtimes are not distributed in the bundle.

The historical version 0.1.1 correction aligned the Lean and JRE whole-directory fingerprints with the exact contents of their already pinned release archives. The original 0.1.0 fingerprints included temporary files outside those archives. That correction changed no archive hashes, individual checker/library hashes, transition definitions or proofs. The verifier continues to reject extra installed files. The adapter addition is a new source revision and requires its own reviewed manifest and complete acceptance receipt.

```bash
python3 tools/bootstrap.py --destination /absolute/path/to/proof-tools
```

The installer downloads the locked Lean, Java and Apalache/TLC releases and installs Quint with `npm ci --ignore-scripts`. It refuses a changed cached archive or runtime distribution. `--offline` is available when the required archives/npm cache or already verified installations exist. Tool downloads are large; they are intentionally kept outside the source package.

Obtain the reviewed source-manifest SHA-256 from the release record or your own source review, then run:

```bash
python3 tools/verify.py \
  --expected-source-sha256 REVIEWED_SOURCE_MANIFEST_SHA256 \
  --lean-root /absolute/path/to/proof-tools/lean-4.35.0-linux \
  --quint-cli /absolute/path/to/proof-tools/quint/node_modules/@informalsystems/quint/dist/src/cli.js \
  --java-bin /absolute/path/to/proof-tools/jdk-21.0.13+9-jre/bin/java \
  --quint-home /absolute/path/to/proof-tools/quint-home \
  --output evidence/recheck
```

`REVIEWED_SOURCE_MANIFEST_SHA256` is deliberately required. Regenerating a manifest does not authorize modified source. After an intentional source change and review, `python3 tools/source_snapshot.py create` creates a new manifest and prints its digest; treat it as a new release.

The output directory must be new or empty. The gate clears this project's generated Lean build, ignores existing project Python bytecode through a fresh cache prefix, checks the source again between stages, requires every stage to complete successfully, checks the tool distributions again at the end, and writes an unsigned `receipt.json` with hashes for logs and evidence artifacts. A timeout, unexpected exit, missing completion marker, changed source, changed tool distribution, unapproved axiom or failed required stage makes the run fail. A negative control passes only when the intended rejection is observed.

### Optional executable-location adapter

The original execution environment has a procfs/PID-namespace mismatch that prevents the stock Lean binary from discovering its own path. `tools/explicit_app_path.c` is a narrowly scoped compatibility adapter used in that run. It supplies the configured toolchain path for a known tool's own executable-location query, and preserves the normal behavior of other `readlink` calls. It does not modify Lean's binaries, libraries or kernel, or change filesystem permissions.

Normal hosts should omit it. If the same startup issue occurs, build it with the installer flag `--build-app-path-adapter` and pass `--app-path-shim /absolute/path/to/proof-tools/toolchain_app_path.so` to the verifier. The receipt records the adapter's identity when present. Its binary is also pinned; a different compiler output requires a reviewed lock update. This environment adaptation and the host OS are part of the disclosed execution boundary.

## Reading the evidence

The receipt separates these evidence classes:

1. **Lean universal proofs** over the actual pure transition definitions, with registered theorem dependencies audited against the explicit standard-axiom allowlist.
2. **Proof dependency replay** from the exported theorem closure, checked by the official kernel and the bundled independent `lean4lean` checker.
3. **Finite model checks** for the explicitly bounded Quint models. Only an exhausted state space counts as a successful safety check.
4. **Adversarial and differential tests**, including actual Lean executable outputs compared against the Python reference. These do not constitute a formal refinement proof of Python or a future database service.
5. **Local adapter conformance**, including authenticated HTTP operations, exact approved proof replay, concurrent database operations and real process-crash/retry tests. These support only the tested local HTTP/SQLite profile and fixture-credit boundary.

The expanded theorem registry contains **75 named properties** across the kernels, acceptance wrapper and terminal closure. The wrapper calls the existing `Reward.accept`; it does not replace the core. Its authenticated-identity and checked-evidence facts, as well as atomic durable publication, are premises. The expanded negative-control set requires seven intended refusals, including an attempted refund on inconclusive checking. Registry membership and control counts do not replace successful exact-revision axiom audit and dual-checker replay.

The original finite Quint models retain seven scenarios and four faulty-transition controls. The adapter model adds 17 scenarios and 12 targeted mutants. Its current finite state space has 676,952 reachable states; acceptance requires exhausting that graph with no states left queued and observing an actual named-invariant counterexample for each mutant. These bounds cover two prepared operations and limited authority/version changes, not arbitrary workers, global accounts, fairness or liveness.

The local receipt is intentionally unsigned. The pilot's verifier route authenticates a configured local credential and produces its own candidate-bound result; a participant cannot become the verifier by returning a JSON receipt or setting `trusted`. Public operation still requires accepted production identity, transport and evidence-custody controls.

Read `docs/VERIFICATION_BOUNDARY.md` before integrating this pilot with a host or public tool protocol. The next production gate is a first-party adapter through existing CoopSubstrate/AgentCore authorization and PostgreSQL persistence, preserving Hawala/TigerBeetle financial authority and avoiding a competing business writer. It must establish exact committed-state correspondence, admission-time revocation, concurrency and recovery under that production storage profile. The local SQLite receipt does not discharge those obligations.

## Upstream references

The implementation pins tool versions in the lock, rather than following documentation's moving defaults:

- [Lean proof validation](https://lean-lang.org/doc/reference/latest/ValidatingProofs/): axiom inspection, exported proof checking and trusted theorem-statement boundaries.
- [Lean 4.35.0 source](https://github.com/leanprover/lean4/tree/v4.35.0): exact checker and export implementation used by this release.
- [Quint 0.33.1](https://github.com/informalsystems/quint/tree/v0.33.1): executable specification and finite-model tooling.
- [Apalache 0.62.4](https://github.com/apalache-mc/apalache/releases/tag/v0.62.4): translation and bundled TLC runtime.

Mathlib and project-specific libraries belong in separately pinned research-task environments. These service-state proofs use Lean's standard library and do not require mathlib.
