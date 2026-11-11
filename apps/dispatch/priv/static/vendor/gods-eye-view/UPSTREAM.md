# God's Eye View — reduced Dispatch viewer

This directory contains a derived subset of God's Eye View's actual viewer
implementation, distributed under the upstream MIT license in `LICENSE`.

- Repository: <https://github.com/bilawalsidhu/gods-eye-view>
- Revision: `14db73f201a0235da4f591648d9b6a9bf4fed87f`
- Source: `src/app/viewer.js`
- Git blob: `e4288e8a3e512ac2ef42f8d5055145d343e1cda6`
- Source SHA-256: `ac64c05180ff03175c7b8143dfe293cdee801d47f68eba9e673106c12c070c91`
- Unmodified upstream LICENSE SHA-256:
  `b231bb38e2d4eab741643126087cbe9df2b58e2f2e5abf27ad613d05f52b01ca`

## Retained source

`viewer.js` derives `zoomOutLimit`, the viewer options, the caller-owned viewer
factory, coarse-pointer zoom adjustment, and the globe zoom bound from that
source. It keeps upstream authorship and preserves the separate visible credit
container. Dispatch adds its own observation renderer and authorized feed.

## Explicit reductions and adaptations

- Resolve Cesium from a pinned, same-origin bundle of explicit engine exports.
- Replace the upstream `Viewer` construction with `CesiumWidget`, which owns
  the scene, camera, entity display and imagery in this pinned version. This
  removes the unused application widgets and their import-time Knockout eval,
  so the page keeps `script-src 'self'` without an eval exception.
- Exclude compressed mesh support from this ellipsoid/raster/point profile.
  The exact `meshoptimizer` import resolves to the build-only
  `meshopt-unavailable.mjs` adapter, which reports unsupported and refuses
  attempted decoding. The build rejects the dependency's five eager
  WebAssembly initializers. No global browser API or CSP permission is changed.
- Retain no upstream application shell, Vue, Pinia, voice, MCP, provider
  settings, public observations, routes, telemetry, share links or agent tools.
- Remove the custom star catalog, star renderer, camera-recovery timers,
  trackpad relay, atmosphere/model workaround and their transitive imports.
- Disable the sky, animation clock and continuous rendering; cap camera
  rendering at 30 FPS and request a frame after each observation update.
- Use only Cesium's bundled Natural Earth II imagery and ellipsoid terrain.
  The image is coarse geographic context, not street mapping or navigation.
- Render actual observed positions without interpolation or dead reckoning.

No God’s Eye View datasets, third-party models, image captures, or media assets
are copied. The full upstream license is retained for its source/data boundary
notice. Cesium has a separate Apache-2.0 license and bundled notices, copied by
the asset build. Natural Earth imagery is bundled in that distribution.

## Reproducibility

From the repository root, run `npm ci --prefix tools/dispatch-globe --ignore-scripts`
then `npm run build --prefix tools/dispatch-globe`. The lockfile pins Cesium
1.138.0, matching the inspected upstream lockfile. The generated, ignored
`../cesium/manifest.json` records every staged asset's byte count and SHA-256.
Pinned esbuild creates the narrow ESM engine bundle and rejects any
`@cesium/widgets` or Knockout input. Aggregate and global Cesium bundles are
excluded; the manifest also inventories the actual bundle inputs. The
no-string-code-generation test reproduces the old import failure and accepts
the new engine without replacing `eval` or weakening browser policy.

Future upstream updates require deliberate source review and updating the
revision and hashes above. No code or dependencies are updated at runtime.

## Local coordinate search

`coordinate-parser.js` is an unmodified copy of upstream
`src/search/coordinateParser.js` at the same pinned revision. It imports no
providers and makes no network requests. Dispatch calls it only to move the
camera; input, coordinates and selection are not put into share links or browser
storage. Place-name geocoding remains unconfigured.

- Git blob: `948cc25e78c5d7efe1361a6f36205a743e55e51e`
- Source and copied-file SHA-256:
  `5ddb08af1affaff83ea04e7c065ab52e7832e4697e9f4158c01e00ece43065fe`

The upstream MIT license and authorship apply. A test binds the copy to these
bytes and exercises strict coordinate rejection rather than guessing a location.
