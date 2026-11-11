export const IDS = ["0193be40-0000-7000-8000-000000000001", "0193be40-0000-7000-8000-000000000002"];

export function snapshot(now = Date.now()) {
  return {
    schema_version: 1,
    status: "ok",
    generated_at: new Date(now).toISOString(),
    limit: 200,
    participants: [
      {
        participant_id: IDS[0], public_name: "North van",
        position: { lat: 47.61, lng: -122.33, accuracy_m: 35,
          occurred_at: new Date(now - 15000).toISOString(), received_at: new Date(now - 10000).toISOString(),
          provider: "fixture", is_mock: false }
      },
      {
        participant_id: IDS[1], public_name: "South van",
        position: { lat: 37.77, lng: -122.42, accuracy_m: 250,
          occurred_at: new Date(now - 310000).toISOString(), received_at: new Date(now - 300000).toISOString(),
          provider: "fixture", is_mock: true }
      }
    ]
  };
}

export const SHELL = `<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Dispatch map acceptance</title><link rel="stylesheet" href="/static/vendor/cesium/Widgets/widgets.css"><link rel="stylesheet" href="/static/css/dispatch-map.css"></head><body><section id="dispatch-map" aria-labelledby="dispatch-map-title"><h1 id="dispatch-map-title">Dispatch map</h1><p id="dispatch-map-status" role="status" aria-live="polite">Connecting…</p><button id="dispatch-map-fit" type="button">Fit locations</button><div id="dispatch-map-globe" aria-label="Observed participant locations"></div><div id="dispatch-map-credits"></div><ul id="dispatch-map-participants" aria-label="Participants"></ul></section></body></html>`;

export const CREDIT_STYLE_HASH = "sha256-W9isZ7K65dw04+sGbSAyiFtvwt94eXJiQXtiU8lmkRg=";
export const CSP = `default-src 'self'; script-src 'self' 'wasm-unsafe-eval'; style-src 'self' '${CREDIT_STYLE_HASH}'; style-src-attr 'unsafe-inline'; img-src 'self' data: blob:; connect-src 'self'; font-src 'self'; worker-src 'self' blob:; object-src 'none'; frame-src 'none'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'`;
