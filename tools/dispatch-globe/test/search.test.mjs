import assert from "node:assert/strict";
import test from "node:test";
import { readFile } from "node:fs/promises";
import { createHash } from "node:crypto";
import { parseCoordinateQuery } from "../../../apps/dispatch/priv/static/vendor/gods-eye-view/coordinate-parser.js";

test("pinned upstream coordinate parser keeps strict local WGS84 semantics", async () => {
  const bytes = await readFile(new URL("../../../apps/dispatch/priv/static/vendor/gods-eye-view/coordinate-parser.js", import.meta.url));
  assert.equal(createHash("sha256").update(bytes).digest("hex"), "5ddb08af1affaff83ea04e7c065ab52e7832e4697e9f4158c01e00ece43065fe");
  for (const query of ["47.61, -122.33", "47.61 N, 122.33 W", "geo:47.61,-122.33;crs=wgs84"]) {
    const result = parseCoordinateQuery(query); assert.equal(result.lat, 47.61); assert.equal(result.lon, -122.33);
  }
  for (const query of ["Seattle", "91, 12", "12, -181", "12junk, 34oops", "-40N, 74W", "geo:12,34,200", "geo:12,34;u=100", "geo:12,34#private", "1e3, 2", ", 34"]) {
    assert.equal(parseCoordinateQuery(query), null, query);
  }
});
