# Fleet

A local Tauri desktop app for working with the fleet — `adder-ws` (this
workstation) and `papa` — in one place. (`mama` was decommissioned 2026-10-16.)

Remote work goes over your existing ssh config, so `papa` resolves
exactly as it does in a terminal. No new credentials, no agent to install on the
far side, nothing listening on a port.

## Panels

| Panel | What it does |
|---|---|
| **Health** | disk, memory, swap, load, failed units, tailnet IP, managed Syncthing status — probed in parallel so one unreachable host doesn't stall the rest |
| **Services** | every systemd unit, user *and* system scope, across all hosts; start/stop/restart/enable/disable |
| **Scripts** | auto-discovers `~/*.sh` and `~/*.py`, runs them with live streamed output and a dry-run/apply split |
| **Configs** | browse and edit settings.json, unit files, drop-ins and hooks — with a diff before every save |

### The restart-limit audit is built in

Services flags any unit whose start limiter can never trip. systemd only stops a
unit after `StartLimitBurst` restarts within `StartLimitIntervalSec`, so when
`RestartSec × Burst >= Interval` the window always resets first and a
permanently-failing unit restarts forever. `pinchtab.service` did this **620,351
times over three days** and its output evicted papa's entire journal.

The `restart-limit bug` chip filters to exactly those units.

## Write posture

Nothing that stops, disables, deletes or overwrites happens without a
confirmation showing the **exact command** — the same string that then runs,
not a paraphrase of it. Scripts default to dry run; `--apply` is a second,
separately-confirmed click.

The backend enforces the half that matters, rather than trusting the UI:

- unit actions are allowlisted (`start|stop|restart|enable|disable`); anything
  else is refused in Rust
- `run_script` refuses any path outside `$HOME` and any argument other than
  `--apply` / `--dry-run`
- `write_config` parses `.json` before replacing it — a malformed
  `settings.json` silently disables every setting in the file
- every config write leaves a timestamped `.bak` beside the original

## Adding a panel

`src/App.tsx` has a registry. Write a component taking `{ hosts }` and add one
row:

```ts
const PANELS: Panel[] = [
  { id: "logs", label: "Logs", component: LogsPanel },
];
```

Backend commands live in `src-tauri/src/`, one module per concern, registered in
`lib.rs`. `exec::run(host, script)` is the primitive everything is built on — it
picks `bash -lc` locally and `ssh` remotely, so a new panel does not care where
it runs.

## Hosts

Defaults are compiled in. To add a box without a rebuild, write
`~/.config/fleet-multitool/hosts.json`:

```json
[
  { "name": "adder-ws", "ssh": null,   "label": "workstation (local)" },
  { "name": "papa",     "ssh": "papa", "label": "papa - EU, openclaw" },
  { "name": "newbox",   "ssh": "newbox", "label": "..." }
]
```

`ssh: null` means "the machine the app is running on".

## Develop / build

```sh
npm run tauri dev      # hot-reload dev window
npm run tauri build    # release .deb + AppImage in src-tauri/target/release/bundle/
cd src-tauri && cargo test
```

## Known limits

- **System-scope actions need sudo.** papa and adder-ws prompt for a password,
  which a GUI has no TTY for, so those actions fail rather than hang. Run privileged changes from a terminal, or via the
  Scripts panel using a script that handles its own `ssh -t`.
- Health reads Syncthing only through `syncthing-policy status`. A host without
  the policy command shows "not managed"; one whose transport is down shows
  "down" with the policy's errors on hover.
- Syncthing config is policy-managed and is not editable here: `write_config`
  refuses any path containing `syncthing`. Use `syncthing-policy reconcile`.
