# God's Eye View — Dispatch viewer and coordinate search

This directory contains a derived subset of God's Eye View's actual viewer
implementation and unmodified coordinate-search modules. The viewer and search
have separate source pins; updating search does not upgrade the viewer or import
the full application. The upstream MIT source license is retained in `LICENSE`.

## Viewer source pin

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

## Local coordinate-search source pin

The three modules below are byte-for-byte copies from upstream revision
[`cb3be34283bb91acface03d19c5a3ada157064dc`](https://github.com/bilawalsidhu/gods-eye-view/commit/cb3be34283bb91acface03d19c5a3ada157064dc),
inspected on 2026-11-15. Only the entry file's name changes from
`coordinateParser.js` to the existing Dispatch name `coordinate-parser.js`.
Its relative imports retain the upstream helper names. The helpers have no
imports; this addition needs no provider, key, network request or npm dependency.
The viewer remains at the older revision recorded above.

| Copied file | Upstream source | Git blob | UTF-8 bytes | Source and copied-file SHA-256 |
| --- | --- | --- | ---: | --- |
| `coordinate-parser.js` | `src/search/coordinateParser.js` | `bbcd1f0244209b51b1f3086232fb78e303212468` | 7,233 | `571bf9e163d86156afd14fecda047b9b74dbaa649e28266deab64a918c57db69` |
| `gridReference.js` | `src/search/gridReference.js` | `c8648c4d599f3f20beb50508c31e9223021b6fb5` | 9,786 | `2bad475b2bc34436daff8087f0774b3c3c51a3f070497fb8b2638a48c009a7f5` |
| `plusCode.js` | `src/search/plusCode.js` | `368536430381ba535080923f95fd8954187e4f5d` | 3,061 | `f46ea8c47fb7acf119e143add5bc7a733f8c0a9ba56d5c97430241df0977aadf` |

The new search source retains the same MIT copyright, permission and warranty
notice as the local `LICENSE`, byte-for-byte. The new upstream license file has
Git blob `86483f2d6d94472b62b0671eef00a3d80a31582d` and SHA-256
`65bfc694b67094c80855179812bcac989da6e55840add547fd2e428b3e4175c3`.
Its later third-party-model note differs from the retained older license file;
this directory imports no models or datasets from either revision. The retained
file and its SHA-256 above continue to cover the unchanged MIT source notice.

The parser adds marked degrees/minutes/seconds, UTM, MGRS and full plus codes to
decimal coordinates and two-dimensional WGS84 `geo:` URIs. The upstream
semantics include two limits that Dispatch's presentation must preserve:

- UTM `N`/`S` may mean a latitude band or hemisphere. Upstream favors band `S`
  (32–40 degrees north) when its northing fits, even where a southern-hemisphere
  reading is also possible. The unchanged vendor module does not remove that
  ambiguity. Dispatch-specific refusal or explicit-hemisphere handling belongs
  in the caller, and tests retain this upstream behavior as a visible constraint.
- Full plus codes identify areas, and the parser returns their centers. MGRS
  100 m and 10 m references also return a square center; 1 m references use its
  corner. A returned decimal point is a search representative, not a claim of
  observation accuracy. Short plus codes, coarse MGRS, unsupported `geo:`
  parameters and malformed or conflicting coordinate components are declined.

Dispatch uses coordinate search only to move the camera. It does not assign a
position to a participant, stop or vehicle, and does not put the input or result
in share links or browser storage. Place-name geocoding remains unconfigured.

`tools/dispatch-globe/test/search.test.mjs` binds all copied bytes to their
upstream Git blobs and SHA-256 hashes. Fixed reference coordinates, boundary and
refusal cases exercise the new formats independently of the conversion code;
the upstream UTM `S` convention is explicitly tested. The runtime/browser checks
remain responsible for the Dispatch caller's policy and lifecycle behavior.
