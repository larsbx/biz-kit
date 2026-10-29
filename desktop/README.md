# biz-kit desktop

A desktop console for the systemd services, scripts, config files and health of
a small set of Linux hosts. Built with Tauri 2, SvelteKit (a static SPA) and TypeScript; runs on
Linux, macOS and Windows.

Remote hosts are reached through your own `ssh` configuration, so an alias from
`~/.ssh/config` resolves exactly as it does in a terminal. No new credentials,
no agent on the far side, nothing listening on a port.

## Panels

| Panel | What it does |
|---|---|
| **Health** | disk, memory, swap, load, failed units and your own checks — hosts are probed in parallel so one unreachable host doesn't stall the rest |
| **Services** | every systemd unit, user *and* system scope, on each host; start/stop/restart/enable/disable |
| **Scripts** | discovers `*.sh` and `*.py` in the scripts directory and runs them locally with live output and a dry-run/apply split |
| **Configs** | browse and edit the files matched by your config patterns, with a diff before every save |
| **Dispatch** | the carrier's dispatch board over dispatch's `/v1/operations`: create loads, add stops, plan trips with a driver and equipment, and start, complete or cancel them |

### Restart-loop audit

Services flags any unit whose start limiter can never trip. systemd only stops
a unit after `StartLimitBurst` restarts within `StartLimitIntervalSec`; when
`RestartSec × StartLimitBurst ≥ StartLimitIntervalSec` the window always resets
first, so a permanently failing unit restarts forever and can flood the
journal. The **restart loop risk** filter shows exactly those units.

## Platform support

| | Linux | macOS | Windows |
|---|---|---|---|
| Runs the app | ✓ | ✓ | ✓ |
| Remote Linux hosts over ssh | ✓ | ✓ | ✓ (built-in OpenSSH client) |
| `local` host (this machine) | ✓ | Services/Health need systemd/Linux | — |
| Scripts panel | `bash`, `python3` | `bash`, `python3` | `python`; `.sh` needs `bash` on `PATH` |

Managed hosts must be Linux with systemd; other kernels are reported as
unsupported rather than shown as empty numbers.

## Configuration

All installation-specific details live in one file, read on every action so
edits apply without a restart:

| OS | Path |
|---|---|
| Linux | `$XDG_CONFIG_HOME/biz-kit/config.json` (default `~/.config/biz-kit/config.json`) |
| macOS | `~/Library/Application Support/biz-kit/config.json` |
| Windows | `%APPDATA%\biz-kit\config.json` |

The exact path is shown at the bottom of the sidebar. Every key is optional; a
missing file means defaults, a malformed one is reported as an error. See
[`config.example.json`](config.example.json).

| Key | Default | Meaning |
|---|---|---|
| `hosts` | `[{ "name": "local", "ssh": null }]` (none on Windows) | `ssh` is an ssh destination or alias; `null` is the machine the app runs on |
| `scriptsDir` | home directory | where the Scripts panel looks |
| `configs` | systemd user units and drop-ins | `{ "path", "label"? }`; paths and globs expand on the target host |
| `protectedPaths` | `[]` | case-insensitive substrings; matching config files are read-only |
| `checks` | `[]` | `{ "label", "command" }` run on each host by Health; exit 0 is healthy and the first output line is shown |
| `dispatch` | none | `{ "api", "auth", "provider" }`: dispatch's base URL, biz-kit's `/auth` base URL, and the sign-in provider's name |

### Dispatch sign-in

The Dispatch panel signs in the way every native biz-kit client does
(`docs/architecture/2026-10-21-native-sign-in.md`): the system browser opens
`/auth/<provider>/native/login` with a PKCE challenge, `/auth` redirects to a
listener on `http://127.0.0.1:47811/callback`, and the code is exchanged for a
session that lasts until **Sign out**. That redirect URI must be in the
server's `BIZKIT_NATIVE_REDIRECT_URIS`; `scripts/e2e-stack.sh` includes it.

The session is kept in `dispatch-session` beside `config.json` (mode 0600) and
never reaches the webview: the panel names a `/v1/` path and the backend makes
the call. Against the dev stack, `"provider": "dispatcher"` signs in as its
seeded dispatcher.

Upgrading from `hosts.json`: move its array under `"hosts"` in `config.json`.

## Write posture

Nothing that stops, disables, deletes or overwrites happens without a
confirmation showing the **exact command** — the same string that then runs.
Scripts default to dry run; `--apply` is a second, separately confirmed click.

The backend enforces the part that matters rather than trusting the UI:

- unit actions are allowlisted (`start|stop|restart|enable|disable`)
- system-scope actions use `sudo -n`, so they fail immediately instead of
  waiting for a password prompt a GUI cannot show; use passwordless sudo rules
  for the units you manage, or a terminal
- `run_script` runs only supported files directly inside the scripts directory,
  with no argument other than `--apply` / `--dry-run`
- `write_config` refuses protected paths and validates `.json` before writing
- every config write leaves a timestamped `.bak` beside the original

## Extending

`src/lib/panels.ts` holds the panel registry. Write a Svelte component in
`src/lib/panels/` taking `let { info }: { info: AppInfo } = $props();` and add
one row:

```ts
export const PANELS: Panel[] = [
  { id: "logs", label: "Logs", component: Logs },
];
```

The frontend is SvelteKit 3 with `@sveltejs/adapter-static` and `ssr = false`
(`src/routes/+layout.ts`): Tauri serves files, so there is no server to render
on. SvelteKit is configured in `vite.config.ts`, and `src/lib` is imported as
`#lib/...` (the `imports` map in `package.json`).

Backend commands live in `src-tauri/src/`, one module per concern, registered
in `lib.rs`. `exec::run(host, script)` is the primitive everything builds on:
it picks a local login `bash` or `ssh`, so a panel doesn't care where it runs.

## Develop / build

Prerequisites: Node 22.17+ (SvelteKit 3), stable Rust, and the
[Tauri system dependencies](https://tauri.app/start/prerequisites/) for your OS.

```sh
npm ci
npm run check                  # svelte-check
npm run tauri dev                  # hot-reload dev window
npm run tauri build                # installers for the current OS
(cd src-tauri && cargo test)
```

`tauri build` produces `.deb`, `.rpm` and AppImage on Linux, `.app` and `.dmg`
on macOS, and `.msi` and NSIS `.exe` on Windows, under
`src-tauri/target/release/bundle/`. Installers are not cross-compiled: build
each on its own OS, or push a `desktop-v*` tag and let
[`.github/workflows/desktop.yml`](../.github/workflows/desktop.yml) build all
three into a draft GitHub release.

Release builds are unsigned unless signing is configured. Unsigned macOS apps
must be opened via right-click → Open; Windows SmartScreen will warn. See the
Tauri guides on [macOS](https://tauri.app/distribute/sign/macos/) and
[Windows](https://tauri.app/distribute/sign/windows/) signing.
