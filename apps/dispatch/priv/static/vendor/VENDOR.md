# Vendored browser dependencies

Section 26.1 requires the Datastar bundle to be committed here, served from the
same origin with a content hash in the filename, and updated only through a
dependency-review change. Production MUST NOT load it from a CDN.

| File | Upstream | Version | SHA-256 |
| --- | --- | --- | --- |
| `datastar-v1.0.4.727844adfc82.js` | https://github.com/starfederation/datastar | v1.0.4 | `727844adfc825ee651fb93c544a2a739986f9a21820a94524b35f0cac470cf91` |

`datastar.js` is an unhashed copy of the same bytes, kept so a reviewer can
diff versions without resolving a hashed filename. The root layout references
the hashed name.

## Updating

`Vendored dependency refresh` (`.github/workflows/vendor-refresh.yml`) checks
upstream weekly and, on a new release, opens that dependency-review change
itself. By hand, the same steps:

1. `scripts/vendor-datastar.sh apps/dispatch/priv/static/vendor [TAG]`
   downloads the release's bundle, replaces both files, and records its
   version and SHA-256 above.
2. The golden Datastar wire-format tests in
   `apps/dispatch/test/dispatch_web/datastar_test.exs` must still pass.
3. Open a dependency-review change; do not update in a feature branch.

Verify a checked-out copy with:

```sh
sha256sum apps/dispatch/priv/static/vendor/datastar-v1.0.4.727844adfc82.js
```
