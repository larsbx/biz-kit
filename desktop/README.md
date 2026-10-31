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
| **Settings** | theme (dark, light, high contrast, or match the OS) and text size; stored per machine in the webview, not in `config.json` |

**Tiles:** panels sit side by side in tiles, as in the Crew Deck. Every tile header has a panel picker, split right, split down, zoom (fill the window; `Esc` restores, the other tiles keep their state) and close. Drag the gap between tiles to resize, double-click it to even it out, or focus it and use the arrow keys. A sidebar panel is added as a tile by splitting the largest one, or highlighted if it is already open; the same panel can be open twice, e.g. Services on two hosts. **Layouts** in the sidebar are presets (Overview, Operate, Everything, Dispatch desk, Single), and the one the tiles still match is marked. The layout is remembered. `Ctrl+B` (or the button above the panel list) folds the sidebar to a rail of icons so the tiles get the width; that is remembered too.

**Navigation:** panels are grouped by what they act on, with a one-line hint under each and ● open / + add. `Ctrl` `1`–`5` adds or highlights a panel, `Ctrl` `,` opens Settings, and `Ctrl` `+`/`-`/`0` change or reset the text size.

Surviving tiles retain their mounted panels when split, resized, zoomed, or moved
by closing a neighbor or inserting a sidebar panel. Duplicate panels have separate
state. Presets and live layout restoration reuse matching panel occurrences in
reading order. Closing or replacing a panel, or selecting a preset that omits it,
removes that instance. Only panel names, split directions, and ratios are saved;
configuration contents and unsaved edits stay in memory and do not survive an
application reload.

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
npm test                       # mounted-component and layout regressions
npm run tauri dev                  # hot-reload dev window
npm run tauri build                # installers for the current OS
(cd src-tauri && cargo test)
```

Linux native acceptance also exercises the actual Tauri/WebKit webview and config
IPC with disposable files and XDG directories. Install `webkit2gtk-driver`,
`xvfb`, and `xauth`, then run:

```sh
cargo install tauri-driver --version 2.0.4 --locked
npm run tauri build -- --debug --no-bundle
xvfb-run -a -s '-screen 0 1920x1080x24' python3 tests/panel-state-native.py src-tauri/target/debug/biz-kit
```

The Desktop workflow runs this acceptance on Linux as well as the frontend and
Rust checks on Linux, macOS, and Windows.

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
