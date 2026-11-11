import { Cesium, createApplicationViewer } from "../../vendor/gods-eye-view/viewer.js";
import { observationPresentation, participantLabel } from "./dispatch-map-model.js";

/** Caller-owned scene. Every position remains a constant admitted observation. */
export function createGlobeView({ container, creditContainer, onSelect = () => {}, onStopSelect = () => {} }) {
  const viewer = createApplicationViewer({ container, creditContainer });
  let destroyed = false;
  let points = [];
  let hasFitted = false;
  let selectedId = null;
  let following = false;
  let work = null;
  const participantEntities = new Map();
  const stopEntities = new Map();

  viewer.screenSpaceEventHandler.setInputAction(event => {
    if (destroyed) return;
    const entity = viewer.scene.pick(event.position)?.id;
    const id = entity?.id;
    if (participantEntities.has(id)) onSelect(id);
    else if (typeof id === "string" && stopEntities.has(id)) onStopSelect(id.slice(5));
    else onSelect(null);
  }, Cesium.ScreenSpaceEventType.LEFT_CLICK);

  function stopFollowing() {
    following = false;
    viewer.trackedEntity = undefined;
    viewer.camera.lookAtTransform(Cesium.Matrix4.IDENTITY);
  }
  function clearWork() {
    for (const entity of stopEntities.values()) viewer.entities.remove(entity);
    stopEntities.clear(); work = null;
    viewer.scene.requestRender();
  }
  function clear() {
    if (destroyed) return;
    stopFollowing(); selectedId = null; work = null;
    participantEntities.clear(); stopEntities.clear();
    viewer.entities.removeAll(); points = []; hasFitted = false;
    viewer.camera.setView({ destination: Cesium.Cartesian3.fromDegrees(0, 0, 25000000),
      orientation: { heading: 0, pitch: -Math.PI / 2, roll: 0 } });
    viewer.scene.requestRender();
  }
  function fit() {
    if (destroyed || points.length === 0) return;
    stopFollowing();
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
  function focusPosition(position) {
    stopFollowing();
    const geographic = Cesium.Ellipsoid.WGS84.cartesianToCartographic(position);
    viewer.camera.setView({ destination: Cesium.Cartesian3.fromRadians(geographic.longitude, geographic.latitude, 20000),
      orientation: { heading: 0, pitch: -Math.PI / 2, roll: 0 } });
    viewer.scene.requestRender();
  }
  return {
    render(snapshot, now = Date.now(), selection = {}) {
      if (destroyed) return;
      selectedId = selection.selectedId || null;
      following = !!selection.following;
      const ids = new Set(); points = [];
      for (const participant of snapshot.participants) {
        const fix = participant.position;
        if (!fix) continue;
        ids.add(participant.participant_id);
        const { color, label } = observationPresentation(fix, now);
        const tint = Cesium.Color.fromCssColorString(color);
        const position = Cesium.Cartesian3.fromDegrees(fix.lng, fix.lat);
        points.push(position);
        let entity = participantEntities.get(participant.participant_id);
        if (!entity) {
          entity = viewer.entities.add({ id: participant.participant_id });
          participantEntities.set(participant.participant_id, entity);
        }
        entity.position = position;
        entity.point = { pixelSize: participant.participant_id === selectedId ? 16 : 11,
          color: tint, outlineColor: participant.participant_id === selectedId ? Cesium.Color.CYAN : Cesium.Color.WHITE,
          outlineWidth: 2, disableDepthTestDistance: Infinity };
        entity.label = { text: `${participantLabel(participant.public_name)}${label ? ` · ${label}` : ""}${fix.is_mock ? " · MOCK" : ""}`,
          font: "13px sans-serif", fillColor: Cesium.Color.WHITE, showBackground: true,
          backgroundColor: Cesium.Color.fromCssColorString("#172334").withAlpha(0.9),
          pixelOffset: new Cesium.Cartesian2(0, -24), disableDepthTestDistance: Infinity };
        entity.ellipse = fix.accuracy_m > 0 ? { semiMajorAxis: Math.min(fix.accuracy_m, 10000000),
          semiMinorAxis: Math.min(fix.accuracy_m, 10000000), height: 1,
          material: tint.withAlpha(0.16), outline: true, outlineColor: tint } : undefined;
      }
      for (const [id, entity] of participantEntities) {
        if (ids.has(id)) continue;
        if (viewer.trackedEntity === entity) stopFollowing();
        viewer.entities.remove(entity); participantEntities.delete(id);
      }
      if (points.length === 0) { clear(); return; }
      viewer.trackedEntity = following && selectedId ? participantEntities.get(selectedId) : undefined;
      if (!hasFitted) { fit(); hasFitted = true; }
      viewer.scene.requestRender();
    },
    renderWork(value, selectedStopId = null) {
      if (destroyed) return;
      clearWork(); work = value;
      for (const stop of work?.stops || []) {
        if (!stop.position) continue;
        const id = `stop:${stop.ref.id}`;
        stopEntities.set(id, viewer.entities.add({ id,
          position: Cesium.Cartesian3.fromDegrees(stop.position.lng, stop.position.lat),
          point: { pixelSize: stop.ref.id === selectedStopId ? 14 : 9, color: Cesium.Color.ORANGE,
            outlineColor: Cesium.Color.WHITE, outlineWidth: 2, disableDepthTestDistance: Infinity },
          label: { text: `Planned ${stop.kind.toLowerCase()} ${stop.sequence}`, font: "12px sans-serif",
            fillColor: Cesium.Color.WHITE, showBackground: true,
            pixelOffset: new Cesium.Cartesian2(0, 20), disableDepthTestDistance: Infinity }
        }));
      }
      viewer.scene.requestRender();
    },
    focus(id) {
      if (destroyed) return;
      const entity = participantEntities.get(id);
      if (entity) focusPosition(entity.position.getValue());
    },
    focusStop(id) {
      if (destroyed) return;
      const entity = stopEntities.get(`stop:${id}`);
      if (entity) focusPosition(entity.position.getValue());
    },
    showCoordinates({ lat, lon }) {
      if (!destroyed) focusPosition(Cesium.Cartesian3.fromDegrees(lon, lat));
    },
    clear, clearWork, fit,
    destroy() {
      if (destroyed) return;
      clear(); destroyed = true;
      viewer.screenSpaceEventHandler.removeInputAction(Cesium.ScreenSpaceEventType.LEFT_CLICK);
      viewer.destroy();
    }
  };
}
