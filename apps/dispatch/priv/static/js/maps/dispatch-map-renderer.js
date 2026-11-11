import { Cesium, createApplicationViewer } from "../../vendor/gods-eye-view/viewer.js";
import { observationPresentation, participantLabel } from "./dispatch-map-model.js";

/** A globe containing only the last authorized, observed coordinates. */
export function createGlobeView({ container, creditContainer }) {
  const viewer = createApplicationViewer({ container, creditContainer });
  let destroyed = false;
  let points = [];
  let hasFitted = false;

  function eraseEntities() {
    if (destroyed) return;
    viewer.entities.removeAll();
    points = [];
  }

  function clear() {
    if (destroyed) return;
    eraseEntities();
    hasFitted = false;
    viewer.camera.setView({
      destination: Cesium.Cartesian3.fromDegrees(0, 0, 25000000),
      orientation: { heading: 0, pitch: -Math.PI / 2, roll: 0 }
    });
    viewer.scene.requestRender();
  }

  function fit() {
    if (destroyed || points.length === 0) return;
    // Use the current canvas aspect ratio before Cesium calculates the range.
    // A fixed multiple of the radius crops points on a wide, short canvas.
    viewer.resize();
    const sphere = Cesium.BoundingSphere.fromPoints(points);
    const shortestSide = Math.min(viewer.canvas.clientWidth, viewer.canvas.clientHeight);
    // Reserve room for point outlines and labels, including their 24px offset.
    const availableShare = Math.max(0.25, 1 - 96 / Math.max(1, shortestSide));
    sphere.radius /= availableShare;
    // Range zero asks Camera.viewBoundingSphere to fit both frustum axes.
    viewer.camera.viewBoundingSphere(sphere, new Cesium.HeadingPitchRange(0, -Math.PI / 2, 0));
    if (Cesium.Cartesian3.distance(viewer.camera.positionWC, sphere.center) < 20000) {
      // Increase a close or single-point fit without reducing a wider fit.
      viewer.camera.viewBoundingSphere(sphere, new Cesium.HeadingPitchRange(0, -Math.PI / 2, 20000));
    }
    viewer.camera.lookAtTransform(Cesium.Matrix4.IDENTITY);
    viewer.scene.requestRender();
  }

  return {
    render(snapshot, now = Date.now()) {
      if (destroyed) return;
      eraseEntities();
      for (const participant of snapshot.participants) {
        const fix = participant.position;
        if (!fix) continue;
        const { color, label } = observationPresentation(fix, now);
        const tint = Cesium.Color.fromCssColorString(color);
        const position = Cesium.Cartesian3.fromDegrees(fix.lng, fix.lat);
        points.push(position);
        viewer.entities.add({
          id: participant.participant_id,
          position,
          point: { pixelSize: 11, color: tint, outlineColor: Cesium.Color.WHITE, outlineWidth: 2, disableDepthTestDistance: Infinity },
          label: {
            text: `${participantLabel(participant.public_name)}${label ? ` · ${label}` : ""}${fix.is_mock ? " · MOCK" : ""}`,
            font: "13px sans-serif", fillColor: Cesium.Color.WHITE,
            showBackground: true, backgroundColor: Cesium.Color.fromCssColorString("#172334").withAlpha(0.9),
            pixelOffset: new Cesium.Cartesian2(0, -24), disableDepthTestDistance: Infinity
          },
          // A zero-radius observation is represented by the point only. Very
          // large reported uncertainty covers the visible hemisphere instead
          // of pretending to be a precise fix; its full value remains in text.
          ...(fix.accuracy_m > 0 ? { ellipse: {
            semiMajorAxis: Math.min(fix.accuracy_m, 10000000),
            semiMinorAxis: Math.min(fix.accuracy_m, 10000000),
            height: 1, material: tint.withAlpha(0.16),
            outline: true, outlineColor: tint
          } } : {})
        });
      }
      if (points.length === 0) { clear(); return; }
      if (!hasFitted && points.length) { fit(); hasFitted = true; }
      viewer.scene.requestRender();
    },
    clear,
    fit,
    destroy() {
      if (destroyed) return;
      clear();
      destroyed = true;
      viewer.destroy();
    }
  };
}
