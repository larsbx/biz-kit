// The portal's live streams (Section 24.5), under Section 26.1's CSP.
//
// Datastar's attributes compile their expressions with `Function()`, which
// `script-src 'self'` forbids, so no page can open its stream through them.
// The wire format needs no expressions: an element names its stream with
// `data-dispatch-stream`, and each `datastar-patch-elements` event replaces the
// elements it carries by id. EventSource does the rest: the server's `retry:`
// hint, and `Last-Event-ID` on a reconnect after a dropped connection.
//
// A stream the server refuses (an ended relationship answers 404) is not
// retried by EventSource. It is reopened afresh, after a bounded exponential
// backoff (Section 26.7), and authorized afresh on the server.

const PREFIX = "elements ";
const FIRST_BACKOFF_MS = 1_000;
const MAX_BACKOFF_MS = 30_000;

/** The elements one event carries: its `data: elements` lines, prefix removed. */
export function elementsOf(data) {
  const html = data
    .split("\n")
    .map((line) => (line.startsWith(PREFIX) ? line.slice(PREFIX.length) : line))
    .join("\n");
  const template = document.createElement("template");
  template.innerHTML = html;
  return [...template.content.children];
}

/** Replaces each element on the page that shares an incoming element's id. */
export function patch(data) {
  for (const incoming of elementsOf(data)) {
    if (incoming.id) document.getElementById(incoming.id)?.replaceWith(incoming);
  }
}

export function open(url, backoff = FIRST_BACKOFF_MS) {
  const source = new EventSource(url);
  source.addEventListener("open", () => (backoff = FIRST_BACKOFF_MS));
  source.addEventListener("datastar-patch-elements", (event) => patch(event.data));
  source.addEventListener("error", () => {
    if (source.readyState !== EventSource.CLOSED) return;
    setTimeout(() => open(url, Math.min(backoff * 2, MAX_BACKOFF_MS)), backoff);
  });
  return source;
}

for (const element of document.querySelectorAll("[data-dispatch-stream]")) {
  open(element.dataset.dispatchStream);
}
