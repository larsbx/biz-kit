import { parseCoordinateQuery } from "../../vendor/gods-eye-view/coordinate-parser.js";
import { parseGridReference } from "../../vendor/gods-eye-view/gridReference.js";
import { parsePlusCode } from "../../vendor/gods-eye-view/plusCode.js";

// Same complete UTM shape as the pinned upstream parser. In UTM alone, S can
// name either the northern latitude band or the southern hemisphere. Require
// another notation instead of inheriting upstream's geographic preference.
// An MGRS band S includes its grid square and does not match this shape.
const UTM = /^(\d{1,2})\s*([C-HJ-NP-X])\s+(\d{6}(?:\.\d+)?)\s*m?\s+(\d{1,7}(?:\.\d+)?)\s*m?$/i;

/** Local camera input only; no identity, observation, provider or persistence. */
export function resolveCoordinateSearch(query) {
  if (typeof query !== "string" || query.length > 160) return { status: "invalid" };
  const text = query.trim();
  const point = parseCoordinateQuery(text);
  if (!point || !Number.isFinite(point.lat) || !Number.isFinite(point.lon) ||
      point.lat < -90 || point.lat > 90 || point.lon < -180 || point.lon > 180) {
    return { status: "invalid" };
  }
  const utm = UTM.exec(text);
  if (utm?.[2].toUpperCase() === "S") return { status: "ambiguous_utm_s" };
  const kind = parsePlusCode(text) ? "area_center"
    : !utm && parseGridReference(text) ? "grid_reference_point" : "coordinate";
  return { status: "ready", point, kind };
}
