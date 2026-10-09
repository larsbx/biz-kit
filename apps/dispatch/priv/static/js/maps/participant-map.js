// The provider-neutral <participant-map> custom element (Section 26.6).
//
// Section 26.1 forbids general application JavaScript in the portal; this
// element and its adapters are the single permitted exception. It therefore
// does the least it can: it holds no domain state, mutates nothing on the
// server, and exposes no global.
//
// Section 26.6 constrains what may cross into the DOM. The element's attributes
// carry only an opaque participant ID and a non-secret version, and coordinates
// are fetched over HTTP and kept in memory — never written to an attribute, a
// Datastar signal, analytics, or a client log.

/** @typedef {{render: (state: object) => void, clear: () => void, destroy?: () => void}} MapAdapter */

/** Adapter factories registered by provider name (Section 28.5). */
const adapters = new Map();

/**
 * Registers a map adapter factory.
 * @param {string} name provider name, e.g. "google" or "maplibre"
 * @param {() => MapAdapter} factory
 */
export function registerMapAdapter(name, factory) {
  adapters.set(name, factory);
}

export class ParticipantMap extends HTMLElement {
  static get observedAttributes() {
    // Section 26.6: the element redraws when data-map-version changes through a
    // Datastar patch. The server decides when the view is stale; the element
    // never polls and never interpolates between samples.
    return ["data-participant-id", "data-map-version", "data-map-provider"];
  }

  #adapter = null;
  #abortController = null;

  connectedCallback() {
    this.#ensureAdapter();
    this.#refresh();
  }

  disconnectedCallback() {
    this.#abortController?.abort();
    this.#abortController = null;
    this.#adapter?.destroy?.();
    this.#adapter = null;
  }

  attributeChangedCallback(name, previous, next) {
    if (previous === next) return;
    if (name === "data-map-provider") {
      this.#adapter?.destroy?.();
      this.#adapter = null;
      this.#ensureAdapter();
    }
    if (this.isConnected) this.#refresh();
  }

  #ensureAdapter() {
    if (this.#adapter) return;
    const provider = this.getAttribute("data-map-provider") || "google";
    const factory = adapters.get(provider);
    // A missing adapter is a configuration error. Rendering nothing is the safe
    // outcome: Section 26.7 requires a textual alternative for every map fact,
    // so the surrounding fragment still carries the information.
    if (!factory) return;
    this.#adapter = factory(this);
  }

  async #refresh() {
    const participantId = this.getAttribute("data-participant-id");
    if (!participantId || !this.#adapter) return;

    this.#abortController?.abort();
    const controller = new AbortController();
    this.#abortController = controller;

    let response;
    try {
      response = await fetch(`/ui/participants/${encodeURIComponent(participantId)}/map-data`, {
        headers: { accept: "application/json" },
        credentials: "same-origin",
        // Section 26.6: the map-data endpoint rechecks precise-location
        // authorization on every request and returns no-store, so the element
        // must never serve this from a cache.
        cache: "no-store",
        signal: controller.signal,
      });
    } catch (error) {
      if (error.name !== "AbortError") this.#adapter.clear();
      return;
    }

    if (!response.ok) {
      // An authorization change mid-session revokes the view. Clearing is the
      // correct response; the element does not retain the last authorized fix.
      this.#adapter.clear();
      return;
    }

    const state = await response.json();
    if (controller.signal.aborted) return;
    this.#adapter.render(state);
  }
}

if (!customElements.get("participant-map")) {
  customElements.define("participant-map", ParticipantMap);
}
