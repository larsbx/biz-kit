import assert from "node:assert/strict";
import test from "node:test";
import { resolveCoordinateSearch } from "../../../apps/dispatch/priv/static/js/maps/dispatch-map-search.js";

test("Dispatch refuses UTM S shorthand without rejecting southern coordinates or MGRS band S", () => {
  // These are opposite-hemisphere conventions, not a rounding discrepancy.
  // The caller receives no guessed point for either convention.
  for (const query of ["54S 383000 3950000", "56S 334900 6252291", "54 s 383000m 3950000m"]) {
    assert.deepEqual(resolveCoordinateSearch(query), { status: "ambiguous_utm_s" }, query);
  }
  const south = resolveCoordinateSearch("54F 383000 3950000");
  assert.equal(south.status, "ready");
  assert.ok(Math.abs(south.point.lat - -54.583932) < 0.00001);
  assert.ok(Math.abs(south.point.lon - 139.189562) < 0.00001);
  for (const query of ["56H 334900 6252291", "33°51′24″S 151°12′55″E", "54SUD1748374870", "33N 500000 4500000"]) {
    assert.equal(resolveCoordinateSearch(query).status, "ready", query);
  }
});

test("search preserves explicit coordinate, MGRS representative-point and plus-code area-center semantics", () => {
  for (const query of ["47.61, -122.33", "47°36′36″N 122°19′48″W", "geo:47.61,-122.33", "18T 585651 4511369"]) {
    const result = resolveCoordinateSearch(query);
    assert.equal(result.status, "ready", query);
    assert.equal(result.kind, "coordinate", query);
    assert.equal("accuracy_m" in result.point, false);
  }
  for (const query of ["18T WL 856 113", "18T WL 8565 1136", "18T WL 85650 11369"]) {
    assert.equal(resolveCoordinateSearch(query).kind, "grid_reference_point", query);
  }
  for (const query of ["849VCWC8+R9", "9R000000+"]) {
    assert.equal(resolveCoordinateSearch(query).kind, "area_center", query);
  }
  const broad = resolveCoordinateSearch("9R000000+");
  assert.equal(broad.point.lat, 60);
  assert.equal(broad.point.lon, 150);
});

test("bounded search declines malformed or contextual input without a partial location", () => {
  for (const query of [null, {}, 47.61, "", "Seattle", "CWC8+R9", "849VCWC8+R9 Seattle",
    "12junk, 34oops", "geo:12,34;u=100", "geo:12,34,200", "1 JAN 2023", "40 26 46 N 79 58 56 W",
    "91, 0", "0, 181", "0, Infinity", "1e3,2", "47.61, -122.33".padEnd(161, " ")]) {
    assert.deepEqual(resolveCoordinateSearch(query), { status: "invalid" }, String(query));
  }
});
