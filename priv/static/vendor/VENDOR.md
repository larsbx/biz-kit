# Vendored browser dependencies

Section 26.1 requires the Datastar bundle to be committed here, served from the
same origin with a content hash in the filename, and updated only through a
dependency-review change. Production MUST NOT load it from a CDN.

| File | Upstream | Version | SHA-256 |
| --- | --- | --- | --- |
| `datastar-v1.0.0.e7d6ad0e8398.js` | https://github.com/starfederation/datastar | v1.0.0 | `e7d6ad0e83980b37706f4494a36db3c58b5dc6cd5a9e5bd5166dbffa6b56a06a` |

`datastar.js` is an unhashed copy of the same bytes, kept so a reviewer can
diff versions without resolving a hashed filename. The root layout references
the hashed name.

## Updating

1. Download the new bundle from the pinned upstream tag.
2. Record its version and SHA-256 above.
3. Run the `web-unit` gate: the golden Datastar wire-format tests in
   `central/test/dispatch_web/datastar_test.exs` and the map custom-element
   tests must both still pass.
4. Open a dependency-review change; do not update in a feature branch.

Verify a checked-out copy with:

```sh
sha256sum central/priv/static/vendor/datastar-v1.0.0.e7d6ad0e8398.js
```
