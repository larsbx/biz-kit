# Machine environment & config — `ubuntu-8gb-evergreen`

Snapshot of the dev host this project lives on. **Accurate as of 2026-07-07**;
re-verify anything load-bearing before depending on it.

## Host

| | |
|---|---|
| Hostname | `ubuntu-8gb-evergreen` |
| OS | Ubuntu 24.04.3 LTS, kernel 6.8, x86_64 |
| Type | Cloud VM (QEMU guest agent running) |
| CPU / RAM | 2 vCPU, 7.6 GiB RAM, **no swap** |
| Disk | 75 GB root (`/dev/sda1`), ~58 GB free |
| User | `admin-papa` (uid 1000); sudo **with password** — no NOPASSWD |

## Network

| | |
|---|---|
| Public IP | `178.156.142.163` |
| Tailscale IP | `100.73.226.23` |
| Tailnet name | `ubuntu-8gb-evergreen.tail2188e6.ts.net` |
| SSH | port 22, open on all interfaces |
| 443 | **Taken** — Tailscale Funnel (see OpenClaw below). Nothing else may bind it. |
| 80 | Free (earmarked for the planned tailnet-only GitLab CE install) |
| 5432 | User-local Postgres, loopback only |
| 18789 | OpenClaw gateway, loopback only (fronted by the Funnel) |

## Services

- **`openclaw.service`** (systemd, runs as `admin-papa`) — OpenClaw Gateway:
  `openclaw gateway --tailscale funnel --auth password`, listening on
  `127.0.0.1:18789`. Its `ExecStartPre` runs `tailscale funnel --bg 18789`,
  which is what holds `https://ubuntu-8gb-evergreen.tail2188e6.ts.net` (443).
- **`tailscaled`**, **`ssh`**, **`qemu-guest-agent`**, **`atd`** — stock.
- **PostgreSQL 16** — *not* a system package and *not* under systemd; see below.

## PostgreSQL (user-local — read this before touching the DB)

A user-local Postgres 16 owned by `admin-papa`, not apt-installed:

- Binaries: `~/pglocal/usr/lib/postgresql/16/bin/` (not on `PATH` — no bare `psql`)
- Data dir: `~/pgdata`
- Listens: `localhost:5432` + Unix socket in `/tmp` (`-k /tmp`)
- Auth: `trust` for all local/loopback connections (`~/pgdata/pg_hba.conf`) —
  no passwords; anything on this box can connect as `postgres`
- Databases for this project: `coop_substrate_eventstore_dev`, `coop_substrate_eventstore_test`

**Caveat: it was started by hand (parent pid 1, no unit file), so it does NOT
survive a reboot.** To start it again:

```sh
~/pglocal/usr/lib/postgresql/16/bin/pg_ctl -D ~/pgdata -o "-p 5432 -k /tmp" -l ~/pgdata/logfile start
```

The project's `config/config.exs` expects exactly this: host `localhost`,
port `5432`, user `postgres`, no password.

## Toolchain

| Tool | Version | Managed by |
|---|---|---|
| Erlang/OTP | 28.3.1 | asdf (`~/.tool-versions`) |
| Elixir | 1.19.5-otp-28 | asdf |
| Rust | 1.96.1 (rustc + cargo) | rustup (`~/.cargo/bin`) |
| git | 2.43.0 | apt |
| glab | 1.106.0 | manual binary in `~/.local/bin` (gitlab.com releases) |
| Tailscale | — | apt, funnel enabled |

asdf shims live at `~/.asdf/shims/`; there is no project-level
`.tool-versions`, so the home-directory one governs.

## Git identity & GitLab

- Global git config (set 2026-07-07): `user.name` = Lars Bendixen,
  `user.email` = larsbendixen@gmail.com, `init.defaultBranch` = main.
- `glab` is installed but **not yet authenticated** — run
  `glab auth login --hostname gitlab.com --stdin <<< "glpat-…"` with a
  personal access token (`api` + `write_repository` scopes), or
  `glab auth login` in an interactive terminal.
- This repo has no remote yet.

## This project

- Repo: `/home/admin-papa/coop_substrate` (see [`quickstart.md`](quickstart.md))
- The Rust NIF (`native/canonical_v1`) compiles against the rustup toolchain
  during `mix compile`.

## Known constraints / planned changes

- RAM is tight (7.6 GiB, no swap) — a GitLab CE install is planned
  (tailnet-only, `external_url` on port 80, memory-tuned, plus a swap file).
  Once done, update this doc: swap, port 80, and new services will change.
- Port 443 cannot be used by anything but the OpenClaw funnel without
  moving that funnel first.
