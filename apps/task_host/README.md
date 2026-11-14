# Task Host blueprint source verification

`mix coop.blueprint` applies a pinned blueprint through the running Task Host
using the operator's governance key. Without a source option, it keeps the
configured Forgejo verifier and existing Forgejo settings.

## Apply a blueprint from a local GitHub checkout

Use [Git **2.45 or newer**](https://git-scm.com/docs/git/2.45.0.html) and a local
clone containing the selected commit and every object along the manifest path.
Fetch the reviewed commit before running this command; the verifier never
fetches missing objects.

```sh
mix coop.blueprint CHAPTER/TENANT/PROJECT larsbx/biz-kit FULL_40_CHARACTER_COMMIT \
  apps/bizops_kb/priv/workflows/office-assistant-onboarding-v1.json \
  --source-checkout /absolute/path/to/biz-kit \
  --server http://127.0.0.1:4001
```

Replace the scope, commit and manifest path with the reviewed adoption pins.
The manifest's project key must equal `PROJECT`. Set `HARNESS_KEYS_DIR` to the
existing governance-key directory. The command shows the repository, commit,
root tree, path, manifest SHA-256, project, roadmaps and workflows before asking
for confirmation; `--yes` accepts it for an already reviewed command.

The checkout's single `remote.origin.url` must identify the supplied GitHub
`OWNER/REPO`, using HTTPS or Git's SSH URL syntax. That mutable local setting is
only a consistency check. It does **not** authenticate GitHub, prove repository
ownership or establish trust in a commit. Select the full commit pin from your
reviewed source and review the shown blueprint before authorizing it.

The local verifier reads raw Git objects and independently recomputes the pinned
commit ID, each directory-tree ID on the selected path, and the final blob ID.
It preserves the exact manifest bytes and calculates their SHA-256 digest.
Working-tree changes, replacement refs, checkout filters and symlinks cannot
substitute source bytes. The selected manifest must have mode `100644`, fit the
configured `blueprint_max_bytes` limit and the hard **1 MiB** limit, and use a
relative ASCII path with no empty, `.` or `..` segments (at most 32 segments).
Commit objects are capped at 64 KiB and each traversed tree at 1 MiB. Missing or
malformed objects, unsupported Git versions, and identity mismatches are errors.

Only raw object reads occur: no hooks, filters, credential helpers or network
fetches run. The governance client still checks that the server's proposed event
binds the exact source pins, scope, manifest digest and blueprint before signing.
Reading or previewing a KB document does not apply a blueprint or create work.
