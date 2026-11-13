# biz-kit desktop

A desktop console for the systemd services, scripts, config files and health of
a small set of Linux hosts. Built with Tauri 2 and plain HTML, CSS and JavaScript modules (no framework, no
bundler), laid out like the Crew Deck; runs on Linux, macOS and Windows.

Remote hosts are reached through your own `ssh` configuration, so an alias from
`~/.ssh/config` resolves exactly as it does in a terminal. No new credentials,
no agent on the far side, nothing listening on a port.

## Panels

| Panel | What it does |
|---|---|
| **Operations** | the task host's Operations workspace (`/operations`): today, upcoming, review, unscheduled, closed and workflows across the projects you are authorized for, running inside the app |
| **Dispatch** | the carrier's dispatch board over dispatch's `/v1/operations`: create loads, add stops, plan trips with a driver and equipment, and start, complete or cancel them |
| **Procurement** | opens the private coordinator console for requests, quotes, orders and evidence |
| **Hosts** | housekeeping for the machines, as four tabs in one tile (each keeps its state when you switch): |
| &nbsp;&nbsp;Health | disk, memory, swap, load, failed units and your own checks — hosts are probed in parallel so one unreachable host doesn't stall the rest |
| &nbsp;&nbsp;Services | every systemd unit, user *and* system scope, on each host; start/stop/restart/enable/disable |
| &nbsp;&nbsp;Scripts | discovers `*.sh` and `*.py` in the scripts directory and runs them locally with live output and a dry-run/apply split |
| &nbsp;&nbsp;Configs | browse and edit matched files, review the exact diff, and save only if the opened version is still current |

**Settings** (`Ctrl ,`, or the sliders button in the title bar) are a sidebar view, as in the Crew Deck: theme (dark, light, high contrast, or match the OS) and text size, stored per machine in the webview, not in `config.json`. Destructive actions are confirmed inside their own tile. Neither is an overlay, because the Operations page is a native webview over its tile and would hide one.

### Operations

The Operations tile shows the task host's own page in a child webview laid over the tile and moved with it, as the Crew Deck lays the game over its tile. The page signs in and authorizes on its own (cookie session, the host's grants); the app adds no authority and the page gets no access to the app's commands. Its address is `operationsUrl` in `config.json`, or `<dispatch.auth>/operations?provider=<dispatch.provider>` when Dispatch is configured. Plain `http` is accepted only for a loopback host; navigation stays on that origin and new windows are refused. Only one tile shows it at a time, and it is hidden while another tile is zoomed. A task host that uses Operations as its home page sets `config :task_host, :after_login_path, "/operations"` so sign-in returns to it. On Linux the page lives in a GTK overlay layer (`src-tauri/src/operations.rs`), because Tauri stacks GTK child webviews in a box instead of overlapping them.

**Composable Operations and TaskHost:** the page inside the Operations tile now
has its own tiling surface, using the desktop's layout model and divider controls.
Workspaces, session controls, the overview, each summary metric, search/category,
work, connection status, and project links can be split, resized, swapped, zoomed,
closed, and reopened. Today, Upcoming, All work, Review, Unscheduled, Closed, and
Workflows are also independent sections, so multiple views can stay visible.
They share the selected workspace, category, and search.

The project's TaskHost page uses the same controls for tasks, suggestions,
workflows, reviews, delegations, history, device enrolment, and each administration
card. **Add section** opens or focuses a section; a tile's picker swaps positions
when that section is already open. Split right/down adds a closed section or an
empty tile with a picker. **Reset layout** restores the starting arrangement.
Drag a divider, use its arrow keys, or press Enter/double-click to even it out.
Zoom fills the page; Escape restores it. Small views scroll the tile surface;
zoom fits one section to the available viewport.

Operations and TaskHost layouts are remembered separately in the page's local
storage. Only section IDs, directions, and ratios are saved. Closing a section
parks its existing DOM, retaining inputs until the page reloads; permission-gated
sections remain unavailable until the existing TaskHost checks expose them.
Task and workflow links reopen the appropriate section. Signing confirmations
retain their existing modal workflow.

The desktop owns `ui/lib/layout.js` and `ui/lib/divider.js`. TaskHost serves
byte-identical copies from its allowlisted static assets. After changing either,
run `node tools/sync-task-tiles.mjs` from `desktop/`; `npm run check` verifies
the copies and syntax-checks both clients. TaskHost must be deployed with these
assets for an installed desktop's remote Operations page to gain the controls.

**Tiles:** panels sit side by side in tiles, as in the Crew Deck. Every tile header has a panel picker, the panel's own controls, split right, split down, zoom (fill the window; `Esc` restores, the other tiles keep their state) and close. Drag the gap between tiles to resize, double-click it to even it out, or focus it and use the arrow keys. A sidebar panel is added as a tile by splitting the largest one, or highlighted if it is already open; the same panel can be open twice, e.g. Hosts showing Services on two machines. **Layouts** in the sidebar are presets (Operations desk, Operations + hosts, Dispatch desk, Single), and the one the tiles still match is marked. The layout is remembered. `Ctrl+B` (or the menu button in the title bar) hides the sidebar so the tiles get the width; that is remembered too. The title bar is the app's own (no system decorations): it carries the hosts, Settings and the window buttons, and drags the window.

**Navigation:** panels are grouped by what they act on, the business ones first, with a one-line hint under each and ● open / + add. `Ctrl` `1`–`4` adds or highlights a panel, `Ctrl` `,` opens Settings, and `Ctrl` `+`/`-`/`0` change or reset the text size.

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
| `procurementOrigin` | none | HTTPS origin of the private procurement service, such as `https://procurement.example.org` |

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

### Procurement

Set `procurementOrigin` in the desktop config and open **Business → Procurement**.
Use an HTTPS origin trusted by the operating system. Enter the coordinator
credential in the console's sign-in form. The dedicated window stays on the
configured origin and has no desktop command permissions. Use the console's
**Sign out** to end its session. The procurement service owns the session,
signing keys, and PostgreSQL data. See the [host runbook](../docs/architecture/2026-11-08-procurement-mvp-host.md).

## Write posture

Nothing that stops, disables, deletes or overwrites happens without a
confirmation showing the **exact command** — the same string that then runs.
Scripts advertising `--apply` are first invoked with an explicit `--dry-run`;
`--apply` is a separate confirmed click. Scripts without that split require a
confirmation showing their exact process arguments before running. Scripts must
honor their declared flags; the console does not sandbox their behavior.

The backend enforces the part that matters rather than trusting the UI:

- unit actions are allowlisted (`start|stop|restart|enable|disable`)
- system-scope actions use `sudo -n`, so they fail immediately instead of
  waiting for a password prompt a GUI cannot show; use passwordless sudo rules
  for the units you manage, or a terminal
- `run_script` runs only supported files directly inside the scripts directory,
  with no argument other than `--apply` / `--dry-run`
- `write_config` refuses protected paths and validates `.json` before writing
- every config write leaves a timestamped `.bak` beside the original
- Save is enabled only after reviewing the current draft's diff; confirmation
  captures that reviewed draft and its opened version
- config review and save reject a file changed since opening, retaining the
  unsaved draft; reload the file before reviewing again
- a per-path lock serializes biz-kit config writers, and a staged replacement
  verifies the original file's owner, group and mode before replacement; symbolic-link saves are refused
  so the operator can open the target directly
- config snapshots travel over process/SSH stdin, allowing large configs without
  embedding their contents in a shell argument

External editors do not participate in biz-kit's lock. The backend compares
opened bytes again immediately before replacement, but this is not a filesystem
transaction with unrelated processes. An interrupted process can leave a
`<config path>.biz-kit-save-lock` directory; remove it only after confirming no
biz-kit save is running.

## Extending

`ui/lib/panels.js` holds the panel registry and documents the panel contract.
Write a module in `ui/panels/` whose default export has an `id`, `label`,
`hint`, `icon`, `group` and a `mount(ctx)` that builds its DOM in `ctx.body`,
and add one import to the registry. The shell (`ui/app.js`) never re-renders a
panel: a tile keeps its DOM through splits, closes, resizes, zoom and preset
changes, so a panel keeps its state in its own closure.

The frontend is `ui/`, served by Tauri as-is (`frontendDist`): `index.html`,
the Crew Deck's `style.css` and `prefs.js`, `app.js` and ES modules under
`ui/lib/` and `ui/panels/`. The Tauri API comes from `withGlobalTauri`.

Backend commands live in `src-tauri/src/`, one module per concern, registered
in `lib.rs`. `exec::run(host, script)` is the primitive everything builds on:
it picks a local login `bash` or `ssh`, so a panel doesn't care where it runs.

## Develop / build

Prerequisites: Node 22+ (only for the Tauri CLI and the tests), stable Rust, and the
[Tauri system dependencies](https://tauri.app/start/prerequisites/) for your OS.

```sh
npm ci
npm run check                  # syntax-check every ui/ module
npm test                       # layout, panel-logic and Operations-placement tests (node --test)
npm run tauri dev                  # dev window serving ui/ directly
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

On headless CI, run the acceptance command under `dbus-run-session --` with
`LIBGL_ALWAYS_SOFTWARE=1`, `WEBKIT_DISABLE_DMABUF_RENDERER=1`,
`WEBKIT_DISABLE_COMPOSITING_MODE=1`, and `NO_AT_BRIDGE=1`. These are test-runner
settings for Xvfb; the application keeps its normal graphics configuration.
The native handshake has a bounded 60-second timeout and prints a separate
session-ready marker before running panel assertions.

The Desktop workflow runs this acceptance on the packaged Linux release binary,
after bundling and before uploading candidates, as well as the frontend and
Rust checks on Linux, macOS, and Windows. Its native test also reviews and saves
a real disposable config, checks the backup, and refuses a stale duplicate
editor without discarding the draft. Linux CI additionally tests a large snapshot
and refuses a group-writable, service-owned config save if ownership cannot be
preserved. The `--service-owner-fixture` test flag uses `sudo` only to create a
disposable root-owned fixture; the actual app runs as the ordinary operator.
The same job uses a disposable trusted HTTPS fixture to check Procurement window
launch, redirects, same-origin navigation, popup blocking and desktop command
denial. The procurement host workflow runs the full lifecycle and restore using
WebKit from the packaged Linux `.deb` against the packaged backend. The private
target deployment still requires its own acceptance run.

Every successful platform job builds installable candidates. Download the
`biz-kit-<platform>-<exact source SHA>` artifact from that Desktop workflow run.
Linux contains `.deb`, `.rpm`, and `.AppImage`; macOS contains a universal `.dmg`;
Windows contains `.msi` and NSIS `.exe`. Each archive includes `provenance.json`
and `SHA256SUMS` for the actual bytes. These are candidate builds without
configured distribution signing; an artifact from one successful platform does
not mean the other platform jobs passed. Release publication still follows the
existing tagged draft-release process.

`python -m unittest discover -s tests -p 'test_*.py'` checks that incomplete,
empty, or stale installer sets cannot be uploaded as complete candidates.

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


Section-layout verification (from the repository root):

```sh
node --test apps/task_host/test/js/*.mjs
node apps/task_host/test/browser/tiles.cjs
```

The browser test uses Playwright and disposable synthetic HTTP fixtures to check
pointer/keyboard resizing, DOM and draft retention, section swapping, close/open,
zoom, persisted layouts, parallel work views, clearing on unauthorized refresh,
small viewport bounds, deep links, and permission-driven visibility. It does not
replace `operations.cjs`'s real identity and signed-ledger acceptance.
