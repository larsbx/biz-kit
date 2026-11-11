import assert from "node:assert/strict";
import test from "node:test";
import { createLocationFeed } from "../../../apps/dispatch/priv/static/js/maps/dispatch-map-feed.js";
import { snapshot } from "./fixtures.mjs";

const flush = async () => { for (let i = 0; i < 12; i++) await Promise.resolve(); };

function harness({ responses = [] } = {}) {
  let clock = Date.UTC(2026, 10, 11, 12);
  let sequence = 0;
  const timers = new Map();
  const observations = [];
  const statuses = [];
  const requests = [];
  const streams = [];
  class Stream {
    constructor(url, options) { this.url = url; this.options = options; this.listeners = new Map(); this.closed = false; streams.push(this); }
    addEventListener(name, callback) { this.listeners.set(name, callback); }
    emit(value) { this.listeners.get("dispatch-locations")?.({ data: typeof value === "string" ? value : JSON.stringify(value) }); }
    close() { this.closed = true; }
    fail() { this.onerror?.(); }
  }
  const response = (value = snapshot(clock), status = 200, type = "application/json") => ({
    ok: status >= 200 && status < 300, status, redirected: false,
    headers: new Headers({ "content-type": type }), text: async () => JSON.stringify(value)
  });
  const feed = createLocationFeed({
    onSnapshot: value => observations.push(value), onStatus: value => statuses.push(value),
    now: () => clock,
    schedule: (callback, delay) => { const id = ++sequence; timers.set(id, { at: clock + delay, callback }); return id; },
    cancel: id => timers.delete(id), EventSourceImpl: Stream,
    fetchImpl: async (url, options) => {
      requests.push({ url, options });
      const next = responses.shift();
      if (next instanceof Error) throw next;
      return typeof next === "function" ? next() : next || response();
    }
  });
  return {
    feed, streams, requests, observations, statuses, timers, response,
    now: () => clock,
    async advance(ms) {
      const end = clock + ms;
      while (true) {
        const next = [...timers].filter(([, timer]) => timer.at <= end).sort((a, b) => a[1].at - b[1].at)[0];
        if (!next) break;
        clock = next[1].at; timers.delete(next[0]); next[1].callback(); await flush();
      }
      clock = end; await flush();
    }
  };
}

test("initial authorized GET is same-origin, uncached, followed by full SSE snapshots", async () => {
  const h = harness(); h.feed.start(); await flush();
  assert.equal(h.requests[0].url, "/ui/operations/locations");
  assert.equal(h.requests[0].options.cache, "no-store");
  assert.equal(h.requests[0].options.credentials, "same-origin");
  assert.equal(h.requests[0].options.redirect, "manual");
  assert.equal(h.streams[0].url, "/ui/operations/locations/stream");
  const next = snapshot(h.now()); next.participants[0].position = null;
  h.streams[0].emit(next);
  assert.equal(h.observations.at(-1).participants[0].position, null);
  h.feed.destroy(); assert.equal(h.observations.at(-1), null);
});

test("disconnect clears before retry and a newly unauthorized GET cannot restore the map", async () => {
  const responses = [];
  const h = harness({ responses }); h.feed.start(); await flush();
  const first = h.streams[0];
  responses.push(h.response({}, 403)); first.fail();
  assert.equal(h.observations.at(-1), null);
  assert.equal(first.closed, true);
  first.emit(snapshot(h.now()));
  assert.equal(h.observations.at(-1), null, "late old stream is fenced");
  await h.advance(1000);
  assert.equal(h.statuses.at(-1), "unavailable");
  assert.equal(h.streams.length, 1);
});

test("401, 403, 404, login HTML and redirects are terminal", async () => {
  for (const status of [401, 403, 404, 302]) {
    const responses = [];
    const h = harness({ responses }); responses.push(h.response({}, status));
    h.feed.start(); await flush();
    assert.equal(h.statuses.at(-1), "unavailable");
    assert.equal(h.streams.length, 0);
    assert.equal(h.timers.size, 0);
  }
  const responses = [];
  const h = harness({ responses }); responses.push(h.response({}, 200, "text/html"));
  h.feed.start(); await flush();
  assert.equal(h.statuses.at(-1), "invalid");
});

test("malformed or over-capacity stream replaces all visible data with none", async () => {
  for (const bad of ["{broken", { ...snapshot(), status: "capacity_exceeded", participants: [] }]) {
    const h = harness(); h.feed.start(); await flush();
    const value = typeof bad === "string" ? bad : { ...bad, generated_at: new Date(h.now()).toISOString() };
    h.streams[0].emit(value);
    assert.equal(h.observations.at(-1), null);
    assert.equal(h.streams[0].closed, true);
    assert.equal(h.timers.size, 0);
  }
});

test("open but silent stream clears at 45 seconds instead of retaining a private fix", async () => {
  const h = harness(); h.feed.start(); await flush();
  await h.advance(44999); assert.notEqual(h.observations.at(-1), null);
  await h.advance(1); assert.equal(h.observations.at(-1), null);
  assert.equal(h.statuses.at(-1), "silent");
  assert.equal(h.streams[0].closed, true);
  h.feed.destroy();
});

test("failed reconnects stop after five bounded exponential delays", async () => {
  const responses = [];
  const h = harness({ responses });
  responses.push(...Array.from({ length: 10 }, () => h.response({}, 503)));
  h.feed.start(); await flush();
  for (const delay of [1000, 2000, 4000, 8000, 16000]) await h.advance(delay);
  assert.equal(h.requests.length, 6);
  assert.equal(h.statuses.at(-1), "disconnected");
  assert.equal(h.timers.size, 0);
});

test("destroy and timed-out fetches fence late results", async () => {
  let resolve;
  const deferred = new Promise(done => { resolve = done; });
  const h = harness({ responses: [() => deferred] });
  h.feed.start(); await flush();
  h.feed.destroy(); resolve(h.response()); await flush();
  assert.equal(h.streams.length, 0);
  assert.equal(h.observations.at(-1), null);
  assert.equal(h.requests[0].options.signal.aborted, true);
});

test("hung GET is cleared and aborted before a bounded reconnect", async () => {
  const h = harness({ responses: [() => new Promise(() => {})] });
  h.feed.start(); await flush(); await h.advance(15000);
  assert.equal(h.requests[0].options.signal.aborted, true);
  assert.equal(h.observations.at(-1), null);
  assert.equal(h.statuses.at(-1), "reconnecting");
  h.feed.destroy();
});
