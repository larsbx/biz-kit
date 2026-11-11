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

- Resolve Cesium from its pinned, same-origin browser distribution.
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
The generated global Cesium bundle is excluded; only its ESM build is served.

Future upstream updates require deliberate source review and updating the
revision and hashes above. No code or dependencies are updated at runtime.
