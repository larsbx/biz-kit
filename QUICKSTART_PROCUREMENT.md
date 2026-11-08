# Procurement MVP: install, run, retain execution evidence

This is the quick start for the **operator-assisted procurement MVP from PR #334**,
not the whole biz-kit umbrella and not a production installer. It builds an isolated
toolchain, runs Lean/Quint first, then runs the existing packaged application
acceptance. The server starts for the tests and stops afterwards; it does **not**
leave a coordinator website running.

## Execution status and revision boundary

PR #334 is merged into `main` at `3eb170b70d3cc16bedfceae865e8d68cf5d2cdbd`.
Its implementation head `76f8156612a498e70277e753dfef15235a20e59b` passed the
[packaged host acceptance](https://github.com/larsbx/biz-kit/actions/runs/42500170637),
including formal replay, PostgreSQL-backed execution, restart, revocation and
backup/restore. The former shared `commercial_setoff_proof.ex` compilation error
and isolated-test dependency gap were repaired in that dependency.

The first [quick-start run](https://github.com/larsbx/biz-kit/actions/runs/42493119708)
passed wrapper controls but failed while building its toolchain: the Hex OTP
archive's enclosing directory was not stripped before invoking `Install`.
The Dockerfile strips that directory and checks the installer and OTP runtime.
The [run on the combined revision](https://github.com/larsbx/biz-kit/actions/runs/42506763260)
built the image, replayed Lean and Quint, and started disposable PostgreSQL.
It stopped compiling `canonical_v1` because the locked `rustler` 0.38.0 requires
Rust 1.91 or later. The image pins Rust 1.91.1 for that dependency.
Use a clean checkout and retain the result of the exact revision you run.
Packaged-release acceptance requires a separate passing Docker receipt for that revision.

## 1. Install the host prerequisites

Supported starting point: **Linux x86-64**, a **local Linux Docker Engine**, Git,
Bash and Python 3.10+. Ubuntu 24.04 is the container base; no Elixir, Erlang, Lean,
Quint, Rust, Node or PostgreSQL installation is needed on your host.

On Ubuntu, install Git and Python through your package manager:

```sh
sudo apt-get update
sudo apt-get install -y git python3
```

Install Docker using its [official Ubuntu instructions](https://docs.docker.com/engine/install/ubuntu/)
(or [your distribution's instructions](https://docs.docker.com/engine/install/)).
`docker info` must work as the account running the quick start. Do not run the whole
repository as root to work around Docker permissions; Docker daemon/group access
is itself privileged. Remote Docker contexts and ARM/emulation are refused by this
initial runner. WSL2 requires Linux-container mode and a local Unix-socket engine;
it has not been separately accepted.

Clone main after PR #337 is merged:

```sh
git clone --branch main https://github.com/larsbx/biz-kit.git
cd biz-kit
git rev-parse HEAD
bash scripts/procurement-quickstart.sh doctor
```

Use normal GitHub SSH/credential-helper authentication for a private repository.
Never put access tokens in the clone URL, command examples or evidence.
Commit or stash source changes: the runner rejects tracked edits and untracked
files except generated `.artifacts/` evidence.

## 2. Install the isolated tools, then run

```sh
bash scripts/procurement-quickstart.sh install
bash scripts/procurement-quickstart.sh run
```

`run` also builds/reuses the toolchain image, so **`run` alone is sufficient** once
the host prerequisites are ready. Normal Docker layer caching avoids repeating
unchanged installation steps. The image uses Elixir 1.19.0 / OTP 27.3.4, Lean 4.19.0,
Quint 0.33.1, Rust 1.91.1, Node 22.16.0, Python 3.12 and PostgreSQL 16. Installed
package versions, tool-download hashes and the built image ID are retained.
Package repositories and transitive downloads are not fully digest-pinned: this
is an inspectable execution environment, **not a claim of bit-reproducible builds**.

The runner takes a fresh shallow snapshot of the exact committed HEAD. It does not
copy your working `.git` configuration, ignored files or local environment into
the container. The build context contains only quick-start toolchain files. Source
is mounted read-only; execution uses a non-root container user. No host database,
Docker socket, host networking, published port or persistent database volume is
provided. Internet access is needed to download tools and locked dependencies.

Inside that disposable container, the sequence is:

1. Check the snapshot and record the actual toolchain.
2. Compile both existing Lean models, reject `sorryAx`, and replay both Quint
   models' type checks, scenarios and 2,000 bounded samples each.
3. Initialize a new loopback PostgreSQL cluster with a fresh random credential.
4. Run `scripts/test-procurement-host.sh` unchanged: reducer/conformance, database
   and HTTP tests, release assembly, then the actual archive with bundled ERTS.
5. Validate all 12 packaged checks, the exact revision and archive SHA-256. Stop
   PostgreSQL, write the overall result and a digest manifest, and copy evidence out.

The existing packaged tests cover HTTPS forms/Secure cookies and CSRF, two quote
revisions and exact acceptance, idempotency, no implied payment, cold restart,
revoked-session refusal without mutation, and backup/restore into a second fresh
database. No governance seed is installed in the long-running service environment.

## 3. Read and check the result

Every invocation prints a **new** directory under
`.artifacts/procurement-quickstart/`. Save that printed path; no `latest` symlink
or previous receipt is treated as a new success.

```sh
# Replace this with the exact directory printed by your run.
RUN_DIR=.artifacts/procurement-quickstart/<printed-directory-name>
cat "$RUN_DIR/revision.txt"
cat "$RUN_DIR/container/result.json"
bash scripts/procurement-quickstart.sh evidence "$RUN_DIR"
```

The evidence command expects the same Git HEAD that ran. To inspect an older run,
use a checkout/worktree of its recorded commit. It rejects a failed result, missing
stages/logs, non-boolean or skipped checks, a wrong revision, a changed archive,
changed logs, or a missing image identity. The outer installation and console logs
are diagnostic context; the **container/** files are covered by its manifest.

| File in the printed run directory | Meaning |
|---|---|
| `revision.txt`, `image.id`, `image.txt` | Requested commit and built toolchain image identity. |
| `install.log`, `console.log` | Installation/startup diagnostics. A failed image build has no application result. |
| `container/result.json`, `container/manifest.json` | Overall stage verdict and retained-file SHA-256 inventory. |
| `container/formal/`, `container/toolchain.log` | Actual formal replay logs and installed versions. |
| `container/runtime.log`, `container/host/` | Application build/test logs and, if built, the release archive. |
| `container/host/release/receipt.json` | Packaged acceptance receipt; absent until the packaged checks finish successfully. |

**Success requires all stages, including cleanup, to be true**, a zero process
exit, and a valid packaged receipt. A successful Docker build, a model proof, a
synthetic runner test, or an archive existing on disk is not application acceptance.
A failure returns nonzero and retains logs; an interrupted run gets best-effort
collection and must not be accepted without a complete result.

Receipts are `unsigned-runner-observation`: their consistency/hash checks do not
make an untrusted runner truthful or authenticate supplied JSON. All data is
synthetic, but inspect logs before sharing. No host environment dump is collected.
These tests do not certify public API security, real payment, legal compliance,
production deployment, graphical-browser behavior, or external evidence backup.

## 4. Run in GitHub Actions instead

The **Procurement MVP quick start** workflow uses the same command on an
`ubuntu-24.04` runner. It first runs the wrapper's adversarial controls, then the
real Docker installation/execution. A final gate rejects failed or skipped jobs;
artifacts are uploaded even after execution failures. Checks use the literal PR
head rather than the pull-request merge ref.

The workflow runs for relevant pull-request and mainline changes. On the default
branch, use **Actions → Procurement MVP quick start → Run workflow** for the desired
branch. Download `procurement-quickstart-<full-sha>` and inspect the run directory
inside it. Always match the evidence revision to the source being evaluated.

## 5. What to do with the release

For a real private coordinator installation, take a **successfully accepted**
`container/host/procurement-release.tar.gz`, verify its digest and use the existing
[host runbook](docs/architecture/2026-11-08-procurement-mvp-host.md#production-configuration-and-explicit-enrollment).
That separate procedure covers persistent storage, secrets, migration, explicit
governance enrollment and loopback HTTP behind an intended HTTPS proxy. Do not
copy the synthetic acceptance database/credentials or bootstrap real governance
from test fixtures. The toolchain container is not a production image.

Actual-host browser acceptance, real enrollment, proxy policy, key custody, backup
of evidence/secrets and compatible rollback remain separate launch gates. Merging
these tools is not deployment approval; cost capture and scorecard export are not
implemented by this quick start.

## Local wrapper controls (no Docker/application execution)

```sh
python3 -m unittest discover -s tests/procurement_mvp -p test_quickstart.py -v
bash -n scripts/procurement-quickstart.sh
```

The Docker subprocess in these controls is deliberately fake. Passing these tests
is evidence about orchestration/rejection behavior only. Full container and
application acceptance still require the real `run` command or hosted workflow.
