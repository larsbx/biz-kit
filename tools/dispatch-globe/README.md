# Dispatch globe assets and acceptance

The runtime dependency is exactly `cesium@1.138.0`. This directory builds no
application bundle and runs no production service. Phoenix serves the staged
ESM module, workers, CSS and bundled Natural Earth II imagery. Dispatch's
derived God’s Eye View constructor and fleet UI remain small plain ESM files.

From the repository root:

```sh
npm ci --prefix tools/dispatch-globe --ignore-scripts
npm run build --prefix tools/dispatch-globe
npm test --prefix tools/dispatch-globe
cd tools/dispatch-globe
npx playwright install --with-deps chromium
npm run test:browser
```

The lockfile pins all transitive dependencies. The asset script copies only
the prebuilt ESM distribution and required asset directories, omitting the
global `Cesium.js` bundle. The generated ignored
`apps/dispatch/priv/static/vendor/cesium/manifest.json` inventories byte sizes
and SHA-256 hashes. No install-time scripts are needed. Include the generated
directory in deployment packaging; it is deliberately absent from Git.

## Tests

Node tests cover protocol validation, the existing freshness thresholds,
accepted device-clock skew, payload/roster bounds, stale-stream clearing,
late-result fences, revocation, login responses, hung requests and bounded
reconnects. They require a staged asset manifest.

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
