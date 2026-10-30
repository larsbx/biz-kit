# adder-ws CD host side

The host half of [`docs/adder-ws-cd.md`](../../docs/adder-ws-cd.md): what
`.github/workflows/deploy-adder-ws.yml` posts to, and what then deploys.
These are copies of the files installed on adder-ws, exported for review. The
installed files are the ones that run; this directory does not install itself.

## What is installed where

Owner: unix account `admin-papa` (uid 1000) on adder-ws, as **user** units of
its systemd manager. Lingering is on, so they run without a login session.

| Repository copy | Installed at |
|---|---|
| `bin/biz-kit-cd` | `~/bin/biz-kit-cd` |
| `bin/biz-kit-cd-gate` | `~/bin/biz-kit-cd-gate` |
| `bin/biz-kit-cd-trigger` | `~/bin/biz-kit-cd-trigger` |
| `systemd/biz-kit-cd-trigger.socket` | `~/.config/systemd/user/biz-kit-cd-trigger.socket` |
| `systemd/biz-kit-cd-trigger@.service` | `~/.config/systemd/user/biz-kit-cd-trigger@.service` |
| `systemd/biz-kit-cd.path` | `~/.config/systemd/user/biz-kit-cd.path` |
| `systemd/biz-kit-cd.service` | `~/.config/systemd/user/biz-kit-cd.service` |
| `systemd/biz-kit-stack.service` | `~/.config/systemd/user/biz-kit-stack.service` |

`test/` is not installed. It is the failure-injection suite below.

State lives in `~/.local/state/biz-kit-cd/`:

| File | Meaning |
|---|---|
| `pending` | a wake-up is due |
| `deployed` | the last good commit |
| `good/` | that commit's `_build/dev`, `deps` and desktop binary, and `good/commit` (about 300 MB) |
| `failed` | a commit that failed to deploy and is not retried; delete it to retry |
| `notified-ci` | the last commit whose CI failure was notified, so it is notified once |
| `lock` | held for the whole deploy |

Logs: `journalctl --user -u biz-kit-cd -u biz-kit-stack -u 'biz-kit-cd-trigger@*'`.

## How a deploy happens

1. **Wake-up:** each time a CI workflow on `main` completes, the workflow
   posts to `biz-kit-cd-trigger.socket` on `100.67.165.25:8791` (tailnet only,
   `Accept=yes`, at most 8 connections, 10 seconds each). Only `POST /deploy`
   is accepted; everything else gets a 404. The body is never read, so a caller
   cannot pass commands, refs, paths or environment.
2. **Acknowledgement:** the trigger writes `pending` atomically and durably
   (synced file, rename, synced directory), then answers **202**. It answers
   **503** if the write fails or `biz-kit-cd.path` is not active.
3. **Start:** `biz-kit-cd.path` (`PathExists=`) starts `biz-kit-cd.service`, and
   starts it again if `pending` exists when a run ends. A wake-up during a
   deploy is therefore not lost, and one accepted before a reboot runs after it.
4. **Checkout checks:** `biz-kit-cd` takes `flock` on `lock`, so manual runs use
   the same lock, and consumes `pending`. It refuses unless `~/biz-kit` is on
   `main` with no tracked, staged or untracked changes (ignored build output is
   fine) and no local commits missing from `origin/main`. Nothing is ever reset
   or cleaned to get past a refusal.
5. **CI gate:** `biz-kit-cd-gate <sha>` reads every GitHub Actions workflow run
   for the head of `origin/main`, except the deploy trigger's own, and keeps
   the latest run per workflow, so a re-run replaces a failure.
   - **Green:** at least one run, and every run completed as success, skipped
     or neutral. The deploy goes ahead.
   - **Pending:** the deploy waits for the next completion's wake-up.
   - **Failed:** the deploy is refused, with one notification per commit.

   It uses workflow runs rather than check runs. GitHub creates every
   triggered workflow's run at push time, but a check run only once its job is
   queued, so counting check runs could pass a commit before its slower
   workflows exist.
6. **Build:** fast-forward only, to the gated commit. Changes are computed from
   the last good commit, not from the checkout's HEAD:
   - `desktop/` changed: rebuild the desktop app (relaunch it yourself)
   - anything else, except `docs/`, `formal/`, `.github/` and `*.md`: run
     `mix deps.get` and `mix compile` first, then restart
     `biz-kit-stack.service`. Unknown paths count as backend.
   - every deploy ends with a health check: the unit is active and both
     `127.0.0.1:4001` and `:4000` answer HTTP
7. **Commit:** copy the artifacts into `good/` (built beside it, then swapped
   in), then write `deployed` atomically.

### Rollback

When any step after the fast-forward fails (compile, desktop build, restart,
health check, or an error no step handles, which the exit trap catches),
`biz-kit-cd`:

- records the commit in `failed`
- moves `main` back to the last good commit with `git reset --keep`, which
  refuses rather than discard local changes
- restores `_build/dev`, `deps` and the desktop binary from `good/`
- restarts the stack if it had been stopped or restarted, after `reset-failed`,
  because the failed deploy's own retries can trip the start limiter
- checks health, notifies, and exits **1**

If the stack is still unhealthy at the last good commit, it notifies
`ROLLBACK FAILED` and exits **2**. A compile failure never touches the running
stack: its loaded code is the last good commit's, and the restored artifacts
match it.

`biz-kit-stack.service` runs `scripts/e2e-stack.sh`, which **recreates the e2e
databases on every start**. Rollback restores code and build artifacts, not
data. A change needing a database migration needs its own cutover plan, as
`docs/adder-ws-cd.md` says. The unit uses the repository's `.tool-versions`
(OTP 27.3.4, Elixir 1.19.0) through asdf, so it sets `PATH` explicitly: the
user manager's own `PATH` has no asdf shims. Its start limiter can trip:
`RestartSec=30` × `StartLimitBurst=3` is less than `StartLimitIntervalSec=600`.

## Failure injection

```sh
deploy/adder-ws-cd/test/run.sh                 # tests bin/biz-kit-cd beside it
deploy/adder-ws-cd/test/run.sh ~/bin/biz-kit-cd
```

Run on adder-ws, it builds a throwaway origin, checkout, fake `mix`/`npx`, fake
gate and a static test unit serving ports 18401/18400, all in a temporary
directory. It never touches `~/biz-kit`, `biz-kit-stack.service` or the live
state, and it removes the test unit when done. It prints every check with the
observed value and exits 0 only if all pass. The three overrides it relies on
(`BIZKIT_STACK_UNIT`, `BIZKIT_HEALTH_PORTS`, `BIZKIT_CD_GATE`) default to the
live values. On 2026-10-30, against the `bin/biz-kit-cd` in this directory:
**59 passed, 0 failed**, and three consecutive runs of an earlier revision were
stable.

| Matrix row (`docs/adder-ws-cd.md`) | Scenario | Result |
|---|---|---|
| Clean main / off-main / detached / tracked edit / untracked / local-ahead / divergence | S9 | each refused with exit 1; edits, files and the local commit kept |
| Fetch or dependency resolution failure | not injected separately | `mix deps.get` failing takes the same branch as S4's compile failure; a failed `git fetch` exits before the fast-forward |
| Backend compile failure | S4 | running stack untouched and still serving; artifacts restored for a cold restart |
| Desktop build failure | S7 | last good binary restored, checkpoint unchanged |
| Retry same fetched HEAD after a failed build | S4, S5 | a failed commit is recorded and not retried; work is diffed against the last good commit |
| Restart or health-check failure | S6, S10 | rolled back and the old stack restarted healthy; an unrecoverable rollback exits 2 with a loud notification |
| Last-good checkpoint | S3, S12 | written last, atomically; an injected error after the fast-forward rolls back without advancing it |
| Two simultaneous deploy invocations | S11 | the second waits on the lock, then deploys |
| Main advances while a deployment is running | live trigger and path unit, 2026-10-30, previous `biz-kit-cd` revision | a wake-up after the marker was consumed caused a second run |
| Wrong method/path, disconnected sender | live trigger, 2026-10-30 | 404 for a wrong path or method; each connection is bounded to 10 s, 8 concurrent (bounds configured, not load-tested) |
| Host restart during accepted work | live path unit, 2026-10-30, previous `biz-kit-cd` revision | a marker left before a simulated reboot was picked up |
| Main acceptance policy | S1, S2, gate | deploys only when every workflow run on the commit is green |

## Not done

- **Tailnet policy.** The ACL limiting `tag:biz-kit-deploy` to adder-ws:8791 is
  not in place, and its positive and negative probes have not been run.
- **Data.** Rollback restores code and artifacts only (see above).
- **The CI gate and `main`.** `main` currently fails the Desktop (macOS) and
  OTP 26 compatibility workflows. Until those are fixed, every deploy is
  correctly refused.

## Install or update on adder-ws

```sh
cd ~/biz-kit/deploy/adder-ws-cd
install -m 755 bin/biz-kit-cd bin/biz-kit-cd-gate bin/biz-kit-cd-trigger ~/bin/
install -m 644 systemd/* ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now biz-kit-cd-trigger.socket biz-kit-cd.path biz-kit-stack.service
```

Rollback needs a `good/` copy. The first successful deploy writes one. Until
then a failure restores the source only, and the notification says so.

## Check the installed copies against this directory

```sh
cd ~/biz-kit/deploy/adder-ws-cd
sha256sum -c SHA256SUMS
for f in bin/*; do cmp "$f" ~/bin/"${f#bin/}"; done
for f in systemd/*; do cmp "$f" ~/.config/systemd/user/"${f#systemd/}"; done
```

`SHA256SUMS` records the installed files as exported. Silence from `cmp` means
the installed files match. Re-export and update both after any change on the
host; acceptance evidence for an older hash is stale.
