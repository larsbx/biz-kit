# Formal Research Exchange — verification core

Proof-first implementation of the acceptance and accounting boundary for a collaborative Lean/Quint research service. The repository contains executable Lean transition functions, theorems about those functions, finite Quint models, a Python reference, and a reproducible local verification gate.

This is the coordinator's verification foundation. It does not yet expose an MCP/UTCP endpoint or accept arbitrary Internet submissions. The trusted `accept` input in the formal model is an explicit premise, not an implemented authentication or theorem-verification service.

## Implemented kernels

**Reward slot:** two eligible participant destinations, one prefunded escrow, expiring leases with generation fencing, exact candidate admission, and atomic acceptance/payout. A candidate binds target, input, environment, policy, artifact, participant, generation and admission timing. Timely admission survives later clock advancement. A paid slot cannot pay again.

**Compute reservation:** reserve an affordable cap, start execution, request cancellation, acknowledge actual stopping, then settle cost and return the unused amount. Funds remain held while execution is running or cancellation awaits acknowledgment. A settled reservation is terminal.

Invalid, well-typed actions return the original state. The model uses natural numbers; global supply, multiple slots and production persistence are outside this release's scope.

## Repository map

| Path | Purpose |
| --- | --- |
| `formal/lean/MODEL_CONTRACT.md` | Shared transition semantics and explicit assumptions |
| `formal/lean/ResearchExchange/` | Executable Lean kernels and their proofs |
| `formal/lean/proof_targets.json` | Nonempty registry of named proof obligations |
| `formal/lean/negative/` | Deliberately invalid proof and axiom-policy controls |
| `formal/quint/` | Finite models, scenarios and model-checking runner |
| `reference/` | Python reference and Lean/Python trace comparison |
| `tests/` | Adversarial state-machine and serialization tests |
| `tools/verify.py` | Reviewed-source gate and evidence orchestration |
| `verification.plan.json` | Required commands, evidence classes and completion criteria |
| `toolchains.lock.json` | Exact runtime distributions and download digests |
| `SOURCE_MANIFEST.json` | Canonical inventory of the reviewed source files |
| `evidence/` | Generated receipts, logs, exported proofs and counterexamples |
| `docs/VERIFICATION_BOUNDARY.md` | Proof scope, assumptions and integration obligations |

## Fast local checks

Python 3.12 or newer is sufficient for the Python checks. No Python packages are required.

```bash
python3 -m unittest discover -s tests -v
python3 -m unittest discover -s tools -p 'test_*.py' -v
```

These are tests, not the full proof verification profile.

## Reproduce the complete profile

The supplied toolchain lock targets Linux x86_64. Install Python 3.12+, Node 24.22.1, npm 11.9.0, and `zstd`; a C compiler is required to build the Lean executable and only if needed the optional application-path adapter. Select npm explicitly with `npm install --global --ignore-scripts --no-audit --no-fund npm@11.9.0`, since the Node release bundles a different npm version. The download installer verifies the pinned archives and the complete installed Lean, JRE, and Quint dependency distributions. The npm lock also pins transitive dependencies. The release receipt records the Python and Node executable identities used for the actual run; these host runtimes are not distributed in the bundle.

Version 0.1.1 corrects the Lean and JRE whole-directory fingerprints to the exact contents of their already pinned release archives. The original 0.1.0 fingerprints included temporary files outside those archives. Archive hashes, individual checker/library hashes, transition definitions and proofs are unchanged. The verifier continues to reject any extra installed files; the correction does not introduce an exclusion rule.

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

The local receipt is intentionally unsigned. For public operation, a controlled verifier must issue a separately authenticated, candidate-bound result. A participant cannot make itself a verifier by returning a JSON receipt or setting `trusted` in a submitted object.

Read `docs/VERIFICATION_BOUNDARY.md` before attaching this kernel to a database or public tool protocol. The most consequential remaining integration requirement is to make acceptance, ledger transfer and persistent state change one atomic transaction. The initial slot has no rejection/reissue transition, so failed admitted candidates also need an explicit future closure path.

## Upstream references

The implementation pins tool versions in the lock, rather than following documentation's moving defaults:

- [Lean proof validation](https://lean-lang.org/doc/reference/latest/ValidatingProofs/): axiom inspection, exported proof checking and trusted theorem-statement boundaries.
- [Lean 4.35.0 source](https://github.com/leanprover/lean4/tree/v4.35.0): exact checker and export implementation used by this release.
- [Quint 0.33.1](https://github.com/informalsystems/quint/tree/v0.33.1): executable specification and finite-model tooling.
- [Apalache 0.62.4](https://github.com/apalache-mc/apalache/releases/tag/v0.62.4): translation and bundled TLC runtime.

Mathlib and project-specific libraries belong in separately pinned research-task environments. These service-state proofs use Lean's standard library and do not require mathlib.
