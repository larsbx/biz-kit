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
| `bin/biz-kit-cd-trigger` | `~/bin/biz-kit-cd-trigger` |
| `systemd/biz-kit-cd-trigger.socket` | `~/.config/systemd/user/biz-kit-cd-trigger.socket` |
| `systemd/biz-kit-cd-trigger@.service` | `~/.config/systemd/user/biz-kit-cd-trigger@.service` |
| `systemd/biz-kit-cd.path` | `~/.config/systemd/user/biz-kit-cd.path` |
| `systemd/biz-kit-cd.service` | `~/.config/systemd/user/biz-kit-cd.service` |
| `systemd/biz-kit-stack.service` | `~/.config/systemd/user/biz-kit-stack.service` |

State lives in `~/.local/state/biz-kit-cd/`: `pending` (a deploy is due),
`deployed` (last good commit) and `lock`. Logs:
`journalctl --user -u biz-kit-cd -u biz-kit-stack -u 'biz-kit-cd-trigger@*'`.

## How a deploy happens

1. **Trigger:** `biz-kit-cd-trigger.socket` listens on `100.67.165.25:8791`
   (tailnet only, `Accept=yes`, at most 8 connections). Each connection runs
   `biz-kit-cd-trigger` for at most 10 seconds. Only `POST /deploy` is accepted;
   everything else gets a 404. The request body is never read, so a caller
   cannot pass commands, refs, paths or environment.
2. **Wake-up:** the trigger writes `pending` atomically and durably (synced
   file, rename, synced directory), then answers **202**. It answers **503** if
   the write fails or `biz-kit-cd.path` is not active, so CI never reports a
   wake-up that nothing will act on.
3. **Start:** `biz-kit-cd.path` (`PathExists=`) starts `biz-kit-cd.service`.
   It starts it again if `pending` exists when a run ends, so a push during a
   deploy is not lost, and a wake-up accepted before a reboot runs after it.
4. **Deploy:** `biz-kit-cd` takes `flock` on `lock`, so manual runs use the
   same lock. It consumes `pending` before any check that can refuse, then:
   - refuses unless `~/biz-kit` is on `main` with no tracked changes, and
     fast-forwards only, never resets or cleans
   - diffs against the last good commit, not the checkout's HEAD, so a failed
     build is retried in full next time
   - rebuilds the desktop app when `desktop/` changed
   - for any other path except `docs/`, `formal/`, `.github/` and `*.md`,
     runs `mix deps.get` and `mix compile` and only then restarts
     `biz-kit-stack.service`, waiting for `127.0.0.1:4001` to listen.
     Unknown paths count as backend.
   - records the new commit in `deployed` (synced temporary file, rename)
     only after every step succeeded
   - fetches again in a loop until `origin/main` stops moving

`biz-kit-stack.service` runs `scripts/e2e-stack.sh`, which **recreates the e2e
databases on every start**. It uses the repository's `.tool-versions` (OTP
27.3.4, Elixir 1.19.0) through asdf, so the unit sets `PATH` explicitly: the
user manager's own `PATH` has no asdf shims. Its start limiter can trip:
`RestartSec=30` × `StartLimitBurst=3` is less than `StartLimitIntervalSec=600`.

## Not implemented

These rows of the acceptance matrix in `docs/adder-ws-cd.md` are open:

- **Artifact rollback.** Builds happen in place in `~/biz-kit/_build` and
  `desktop/src-tauri/target`. A failed compile leaves the running stack up,
  but a failed restart is not rolled back to retained artifacts.
- **Main acceptance policy.** The deploy does not wait for the commit's CI
  checks.
- **Tailnet policy.** The ACL limiting `tag:biz-kit-deploy` to adder-ws:8791
  is not in place, and its positive and negative probes have not been run.

## Install or update on adder-ws

```sh
cd ~/biz-kit/deploy/adder-ws-cd
install -m 755 bin/biz-kit-cd bin/biz-kit-cd-trigger ~/bin/
install -m 644 systemd/* ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now biz-kit-cd-trigger.socket biz-kit-cd.path biz-kit-stack.service
```

## Check the installed copies against this directory

```sh
cd ~/biz-kit/deploy/adder-ws-cd
sha256sum -c SHA256SUMS
for f in bin/*; do cmp "$f" ~/bin/"${f#bin/}"; done
for f in systemd/*; do cmp "$f" ~/.config/systemd/user/"${f#systemd/}"; done
```

`SHA256SUMS` records the files as exported on 2026-10-30. Silence from `cmp`
means the installed files match. Re-export and update both after any change on
the host; acceptance evidence for an older hash is stale.
