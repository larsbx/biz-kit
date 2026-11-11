// Derived from God's Eye View, copyright (c) 2026 Bilawal Sidhu, MIT.
// Upstream source and exact reductions are recorded in UPSTREAM.md.
import * as Cesium from "../cesium/index.js";

const MIN_GLOBE_SHARE = 0.3;

export function zoomOutLimit(fovy) {
  const radius = Cesium.Ellipsoid.WGS84.maximumRadius;
  const angular = Math.atan(MIN_GLOBE_SHARE * Math.tan(fovy / 2));
  return radius / Math.sin(angular) - radius;
}

/** GEV's reduced scene options; CesiumWidget has no application controls. */
export function applicationViewerOptions(creditContainer) {
  return {
    baseLayer: false,
    skyBox: false,
    skyAtmosphere: false,
    creditContainer,
    msaaSamples: 4,
    requestRenderMode: true,
    maximumRenderTimeChange: Infinity,
    shouldAnimate: false
  };
}

/** Create a caller-owned GEV globe. Dispatch supplies all observation data. */
export function createApplicationViewer({ container, creditContainer }) {
  if (!container || !creditContainer) throw new TypeError("Viewer and credit containers are required");
  Cesium.buildModuleUrl.setBaseUrl(new URL("../cesium/", import.meta.url).href);
  const viewer = new Cesium.CesiumWidget(container, applicationViewerOptions(creditContainer));
  try {
    viewer.targetFrameRate = 30;
    if (globalThis.matchMedia?.("(pointer: coarse)").matches) {
      viewer.scene.screenSpaceCameraController.zoomFactor *= 3;
    }
    viewer.scene.preRender.addEventListener(() => {
      const { scene, camera } = viewer;
      const fovy = camera.frustum.fovy;
      scene.screenSpaceCameraController.maximumZoomDistance =
        scene.mode === Cesium.SceneMode.SCENE3D && Number.isFinite(fovy)
          ? Math.max(zoomOutLimit(fovy), camera.positionCartographic?.height ?? 0)
          : Infinity;
    });
    // Bundled low-resolution imagery is the only basemap. Ellipsoid terrain
    // needs no account, remote tiles, geocoder, terrain server or API token.
    viewer.imageryLayers.addImageryProvider(new Cesium.UrlTemplateImageryProvider({
      url: Cesium.buildModuleUrl("Assets/Textures/NaturalEarthII/{z}/{x}/{reverseY}.jpg"),
      tilingScheme: new Cesium.GeographicTilingScheme(),
      maximumLevel: 2,
      credit: "Natural Earth II · bundled imagery"
    }));
    viewer.scene.globe.show = true;
    viewer.scene.globe.enableLighting = false;
    viewer.scene.backgroundColor = Cesium.Color.fromCssColorString("#0b1727");
    return viewer;
  } catch (error) {
    viewer.destroy();
    throw error;
  }
}

export { Cesium };
