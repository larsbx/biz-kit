# Open Procurement from the desktop

Procurement is a separate, authenticated HTTPS service. Installing the Tauri app
or running the disposable evidence quick start does not install a persistent
Procurement service. The quick-start test server stops when acceptance finishes.

## Desktop connection

Open **Business → Procurement** in the desktop sidebar. A fresh installation
shows **Setup required**, a server-address field, and a disabled launch button.
Enter the HTTPS origin of your running Procurement service, for example
`https://procurement.example.org:8443` (replace this example). Use an origin only:
no `/login` or `/operations` path, embedded credentials, query, or fragment.

Choose **Save server address**, review the target file and before/after address,
and confirm **Save address**. Then choose **Open procurement console** and sign
in in its dedicated window. Saving does not contact the server or send credentials.
A configured address or an opened window is not evidence of server health.

Use **Reload connection** after editing the desktop configuration outside the app.
Close the Procurement window before changing to a different server. Opening an
existing window restores it from minimization before focusing it.

The command changes only the `procurementOrigin` value in the existing desktop
`config.json`; unrelated and unknown JSON fields are retained (formatting may
change). A content revision guards against stale reviews. Writes use the existing
Configs-editor lock convention and a staged replacement, with Unix owner/group
and permission checks. This lock coordinates biz-kit writers, not unrelated
external programs. Malformed settings and final-path symlinks are refused rather
than replaced with defaults. The address is not stored in browser storage.

## Existing builds without in-app setup

The existing desktop also has **Business → Procurement → Open procurement console**,
but requires `procurementOrigin` to be set by editing the settings file. Its path
is displayed in the app; the usual Linux path is
`$XDG_CONFIG_HOME/biz-kit/config.json`, or `~/.config/biz-kit/config.json` when that
environment variable is not set. Add/update this field in the existing JSON object
without replacing other settings:

```json
"procurementOrigin": "https://your-running-procurement-server.example"
```

The native opener rereads the file on every launch. No TLS bypass or default
server is provided. A missing sidebar entry can also mean an older installed
binary: changing or merging repository source does not replace that binary.
Use an accepted desktop installer whose source revision matches the change.

## Execution evidence

Local UI controls:

```sh
cd desktop
node --test ui/panels/procurement.test.js
```

Native backend controls, with the desktop build prerequisites installed:

```sh
cd desktop/src-tauri
cargo test --locked procurement
```

The Desktop workflow runs the frontend tests, Rust tests, installer build and
native Linux HTTPS fixture. `tests/panel-state-native.py` must exercise missing
configuration, cancellation, reviewed save, reload persistence, launch, same-origin
navigation, popup refusal and denial of desktop IPC from the remote window.

The separate packaged application acceptance in
`../tests/procurement_mvp/tauri_client.py` also starts without `procurementOrigin`,
uses the visible setup/review/open controls, checks that unrelated configuration
survives, and only then reaches the real Procurement login and existing lifecycle.
It must not inject the origin into configuration to bypass first-run setup.

The changed JavaScript tests use a DOM/IPC double. Python compilation checks syntax
only. Neither substitutes for Rust compilation, native WebKit execution, the
packaged backend acceptance, or a check on the user's installed machine. Record
an exact-head hosted result before calling the native fix accepted. No business
admission rule, authority, session, TLS check, or receipt requirement is relaxed.
