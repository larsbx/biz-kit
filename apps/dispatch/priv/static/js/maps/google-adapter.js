// Google presentation adapter for <participant-map> (Section 28.5).
//
// Section 28.4 and 28.5 keep provider objects inside their adapter. Nothing
// here leaks a Google type back to the element, so the MapLibre migration
// target replaces this file alone — no HEEx component, Datastar signal, Ash
// resource, or fragment ID changes.

import { registerMapAdapter } from "./participant-map.js";
import { freshness } from "./map-freshness.js";

class GoogleParticipantMapAdapter {
  #host;
  #map = null;
  #marker = null;
  #accuracyCircle = null;
  #routeLine = null;

  constructor(host) {
    this.#host = host;
  }

  render(state) {
    if (!globalThis.google?.maps) return;
    this.#ensureMap();

    const { location, route } = state;
    if (!location) {
      this.clear();
      return;
    }

    const position = { lat: location.lat, lng: location.lng };
    const { color, label } = freshness(location.age_seconds ?? 0);

    // Section 26.6: never interpolate a moving marker beyond the last sample.
    // The marker is placed, not animated.
    this.#marker ??= new google.maps.Marker({ map: this.#map });
    this.#marker.setPosition(position);
    this.#marker.setIcon({
      path: google.maps.SymbolPath.CIRCLE,
      scale: 8,
      fillColor: color,
      fillOpacity: 1,
      strokeWeight: 0,
    });
    this.#marker.setTitle(label ? `Last location (${label})` : "Last location");

    // Accuracy is always drawn. Section 6.1 requires portal markers to show
    // accuracy and age, so a precise-looking dot over a 400 m fix is not an
    // option the adapter can offer.
    this.#accuracyCircle ??= new google.maps.Circle({ map: this.#map, strokeWeight: 1 });
    this.#accuracyCircle.setCenter(position);
    this.#accuracyCircle.setRadius(location.accuracy_m ?? 0);
    this.#accuracyCircle.setOptions({ strokeColor: color, fillColor: color, fillOpacity: 0.12 });

    this.#renderRoute(route);
    this.#map.setCenter(position);
  }

  clear() {
    this.#marker?.setMap(null);
    this.#accuracyCircle?.setMap(null);
    this.#routeLine?.setMap(null);
    this.#marker = this.#accuracyCircle = this.#routeLine = null;
  }

  destroy() {
    this.clear();
    this.#map = null;
  }

  #ensureMap() {
    this.#map ??= new google.maps.Map(this.#host, {
      zoom: 11,
      disableDefaultUI: true,
      zoomControl: true,
    });
  }

  #renderRoute(route) {
    // Section 26.6 fits route and stops only after the server has decided the
    // viewer may see them, so an absent route means "not authorized or not
    // computed" and is drawn as nothing rather than guessed at.
    if (!route?.geometry?.coordinates?.length) {
      this.#routeLine?.setMap(null);
      this.#routeLine = null;
      return;
    }

    const path = route.geometry.coordinates.map(([lng, lat]) => ({ lat, lng }));
    this.#routeLine ??= new google.maps.Polyline({ map: this.#map, strokeWeight: 3 });
    this.#routeLine.setPath(path);
  }
}

registerMapAdapter("google", (host) => new GoogleParticipantMapAdapter(host));
