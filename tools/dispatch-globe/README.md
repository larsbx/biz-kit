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
# First install the pinned formal toolchains as described in the safety document.
bash formal/check_dispatch_spatial.sh
npm test --prefix tools/dispatch-globe
cd tools/dispatch-globe
npx playwright install --with-deps chromium
npm run test:browser
```

The lockfile pins all transitive dependencies. `cesium-entry.mjs` includes
`CesiumWidget` and the engine types used by Dispatch. It excludes `Viewer` and
the `@cesium/widgets` application UI, whose Knockout dependency evaluates code
at import time even with visible widgets disabled. The build rejects that
dependency graph, preserving the page's strict `script-src 'self'` policy.
The selected ellipsoid/raster/point profile also excludes compressed mesh
models and terrain. Its exact `meshoptimizer` build alias reports unsupported
and fails on attempted decode. This avoids the aggregate dependency's five
eager WebAssembly initializations without granting `wasm-unsafe-eval` or
changing global browser APIs. The build rejects any meshoptimizer input; a
negative-control test reproduces the five initializations in the unadapted
dependency and verifies zero in the emitted engine. This restriction applies
to Dispatch's derived profile, not upstream God’s Eye View or Cesium.
The asset script stages the engine bundle, prebuilt workers/assets, and only
the core CesiumWidget stylesheet. It omits the aggregate/global bundles and
unused widget styles. The generated ignored
`apps/dispatch/priv/static/vendor/cesium/manifest.json` inventories byte sizes
and SHA-256 hashes, plus the bundle's input inventory. No install-time scripts
are needed. Include the generated
directory in deployment packaging; it is deliberately absent from Git.

## Tests

The Dispatch acceptance workflow runs
[`formal/check_dispatch_spatial.sh`](../../formal/check_dispatch_spatial.sh)
before either database or browser acceptance. The
[safety document](../../formal/DISPATCH_SPATIAL_SAFETY.md) records toolchain
installation, propositions, finite model limits, meaningful unsafe controls and
the mapping to runtime tests. A successful model does not establish real
authorization, rendering or device collection by itself.

Node tests cover protocol validation, the existing freshness thresholds,
accepted device-clock skew, payload/roster bounds, stale-stream clearing,
late-result fences, revocation, login responses, hung requests and bounded
reconnects. They also check V2 scope, typed references, complete coverage,
strictly increasing stream cursors, selected-work observation bindings,
independent work authority, cancellation races and coordinate-parser provenance.
They require a staged asset manifest. An import gate disables
string code generation in Node and checks the emitted engine, with the
original aggregate bundle as a negative control that reproduces the failure.
This catches the import-time defect without weakening browser CSP; the real
browser gate still establishes WebGL behavior. The tests also compare the
browser fixture's policy with the literal production controller policy.

The Playwright gate starts a loopback HTTP server serving the real static
modules with synthetic observations, then runs the actual WebGL renderer. It
observes real Cesium entity lifetimes, positions and uncertainty, verifies
the credit-style CSP hash, tests empty/invalid/revoked states and the BFCache
reload, and rejects external requests and unhandled errors. It exercises
selection/follow, planned-stop and record links, filtering, keyboard focus,
local coordinate search, delayed work, permission loss and a 390-pixel layout.
It also verifies the textual fallback when the renderer is unavailable. It does not stand in
for the separate Phoenix/PostgreSQL authorization and stream tests.

Use the installed Playwright Chromium by default. `DISPATCH_CHROMIUM` may name
another available Chromium executable. CPU SwiftShader is enabled for CI's
headless WebGL test; production browser settings are unchanged. Browser
artifacts are written to ignored `artifacts/`.

## Selected profile and budgets

[`profile.json`](profile.json) records exact source pins, required devices,
capability selection and acceptance budgets. The build rejects package or
engine byte overflow; the browser reports cold same-origin response bodies,
requests, time until the first observation, JavaScript heap and browser/viewport
context. The measured fixture is a loopback, headless Chromium/SwiftShader run,
not a production latency or physical-device claim.

| Boundary | Acceptance limit |
| --- | --- |
| Staged assets, including workers/imagery | 12 MiB |
| Explicit engine bundle | 6 MiB |
| Cold first-view response bodies | 12 MiB |
| Cold first-view requests | 200 |
| First observation ready | 20 seconds |
| Browser JavaScript heap | 256 MiB |
| Snapshot | 200 participants and 256 KiB |
| Selected work | 200 planned stops and 64 KiB |
| External requests / business mutations | 0 / 0 |
| Additional runtime server processes / databases | 0 / 0 |

The final row describes this integration's architecture, not the existing
Dispatch platform's total process count. The earlier auxiliary deployment was
proposed only, so no measured legacy service or resource-saving baseline exists.
Local imagery is coarse global orientation. Address search, routing,
optimization, compressed meshes, historical replay and private saved views
remain explicitly unavailable in this profile.

For a manual check with synthetic data only, run
`DISPATCH_GLOBE_SERVE=1 npm run test:browser`; it prints a loopback URL and
refreshes fixture snapshots every 20 seconds. Stop that process when done.

The production page is `/operations/map`; it uses authenticated Dispatch
snapshots and the stream, never this fixture server. No public data feed,
external tile provider, account, API token, voice system or CDN is involved.
