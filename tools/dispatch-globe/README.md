# Dispatch globe assets and acceptance

The runtime dependency is exactly `cesium@1.138.0`. This directory bundles a
small explicit engine entry with pinned `esbuild@0.28.2`; it runs no production
service. Phoenix serves that ESM module, workers, CSS and bundled Natural Earth
II imagery. Dispatch's derived God’s Eye View constructor and fleet UI remain
small plain ESM files.

From the repository root:

```sh
npm ci --prefix tools/dispatch-globe --ignore-scripts
npm run build --prefix tools/dispatch-globe
npm test --prefix tools/dispatch-globe
cd tools/dispatch-globe
npx playwright install --with-deps chromium
npm run test:browser
```

The lockfile pins all transitive dependencies. `cesium-entry.mjs` includes
`CesiumWidget` and the engine types used by Dispatch. It excludes `Viewer` and
the `@cesium/widgets` application UI, whose Knockout dependency evaluates code
at import time even with visible widgets disabled. The build rejects that
dependency graph, preserving the page's prohibition on JavaScript string
evaluation. Cesium's mesh decoder eagerly initializes WebAssembly. The map
allows that through `script-src 'self' 'wasm-unsafe-eval'`, while JavaScript
`eval`, `Function` compilation and inline scripts remain blocked. The build
resolves `meshoptimizer` to its official `meshoptimizer/decoder` export,
excluding the unused encoder, simplifier, clusterizer and tangent generator.
The asset script stages the engine bundle, prebuilt workers/assets, and only
the core CesiumWidget stylesheet. It omits the aggregate/global bundles and
unused widget styles. The generated ignored
`apps/dispatch/priv/static/vendor/cesium/manifest.json` inventories byte sizes
and SHA-256 hashes, plus the bundle's input inventory and resolver alias. No
install-time scripts are needed. Include the generated
directory in deployment packaging; it is deliberately absent from Git.

With the pinned lockfile, staged assets total 9,196,088 bytes across 318 files
(excluding the manifest); the ESM bundle is 3,656,534 bytes. The decoder-only
entry removes 120,769 bytes and four eager WebAssembly initializations from
the focused engine bundle.

## Tests

Node tests cover protocol validation, the existing freshness thresholds,
accepted device-clock skew, payload/roster bounds, stale-stream clearing,
late-result fences, revocation, login responses, hung requests and bounded
reconnects. They require a staged asset manifest. An import gate disables
string code generation in Node and checks the emitted engine, with the
original aggregate bundle as a negative control that reproduces the failure.
This catches the import-time JavaScript evaluation defect; the real
browser gate still establishes WebGL behavior. The tests also compare the
browser fixture's policy with the literal production controller policy and
exclude unused Meshoptimizer tools from the build graph.

The Playwright gate starts a loopback HTTP server serving the real static
modules with synthetic observations, then runs the actual WebGL renderer. It
observes real Cesium entity lifetimes, positions and uncertainty, verifies
the credit-style CSP hash, tests empty/invalid/revoked states and the BFCache
reload, and rejects external requests and unhandled errors. It also verifies
the textual fallback when the renderer is unavailable. It does not stand in
for the separate Phoenix/PostgreSQL authorization and stream tests.

Use the installed Playwright Chromium by default. `DISPATCH_CHROMIUM` may name
another available Chromium executable. CPU SwiftShader is enabled for CI's
headless WebGL test; production browser settings are unchanged. Browser
artifacts are written to ignored `artifacts/`.

For a manual check with synthetic data only, run
`DISPATCH_GLOBE_SERVE=1 npm run test:browser`; it prints a loopback URL and
refreshes fixture snapshots every 20 seconds. Stop that process when done.

The production page is `/operations/map`; it uses authenticated Dispatch
snapshots and the stream, never this fixture server. No public data feed,
external tile provider, account, API token, voice system or CDN is involved.
