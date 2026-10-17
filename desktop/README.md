# biz-kit desktop

A desktop console for the systemd services, scripts, config files and health of
a small set of Linux hosts. Built with Tauri 2, React and TypeScript; runs on
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

`src/App.tsx` holds the panel registry. Write a component taking
`{ info }: { info: AppInfo }` and add one row:

```ts
const PANELS: Panel[] = [
  { id: "logs", label: "Logs", component: LogsPanel },
];
```

Backend commands live in `src-tauri/src/`, one module per concern, registered
in `lib.rs`. `exec::run(host, script)` is the primitive everything builds on:
it picks a local login `bash` or `ssh`, so a panel doesn't care where it runs.

## Develop / build

Prerequisites: Node 20+, stable Rust, and the
[Tauri system dependencies](https://tauri.app/start/prerequisites/) for your OS.

```sh
npm ci
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
