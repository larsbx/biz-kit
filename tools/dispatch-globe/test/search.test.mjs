import assert from "node:assert/strict";
import test from "node:test";
import { readFile } from "node:fs/promises";
import { createHash } from "node:crypto";
import { parseCoordinateQuery } from "../../../apps/dispatch/priv/static/vendor/gods-eye-view/coordinate-parser.js";
import { parseGridReference } from "../../../apps/dispatch/priv/static/vendor/gods-eye-view/gridReference.js";
import { parsePlusCode } from "../../../apps/dispatch/priv/static/vendor/gods-eye-view/plusCode.js";

const vendor = new URL("../../../apps/dispatch/priv/static/vendor/gods-eye-view/", import.meta.url);

// Exact public source at cb3be34283bb91acface03d19c5a3ada157064dc.
// Git object IDs also bind the bytes' length and UTF-8 encoding. Dispatch
// adaptations belong outside these unchanged upstream modules.
const sourceFiles = [
  ["coordinate-parser.js", 7233, "bbcd1f0244209b51b1f3086232fb78e303212468", "571bf9e163d86156afd14fecda047b9b74dbaa649e28266deab64a918c57db69"],
  ["gridReference.js", 9786, "c8648c4d599f3f20beb50508c31e9223021b6fb5", "2bad475b2bc34436daff8087f0774b3c3c51a3f070497fb8b2638a48c009a7f5"],
  ["plusCode.js", 3061, "368536430381ba535080923f95fd8954187e4f5d", "f46ea8c47fb7acf119e143add5bc7a733f8c0a9ba56d5c97430241df0977aadf"],
];

function nearDegrees(actual, lat, lon, tolerance = 1e-9) {
  assert.ok(actual, `expected a point near ${lat}, ${lon}`);
  assert.ok(Math.abs(actual.lat - lat) <= tolerance, `latitude ${actual.lat} differs from ${lat}`);
  assert.ok(Math.abs(actual.lon - lon) <= tolerance, `longitude ${actual.lon} differs from ${lon}`);
}

// Independent spherical separation; does not repeat the inverse
// transverse-Mercator conversion being checked against fixed coordinates.
function metresBetween(actual, lat, lon) {
  assert.ok(actual, `expected a point near ${lat}, ${lon}`);
  const r = Math.PI / 180;
  const h = Math.sin((lat - actual.lat) * r / 2) ** 2 +
    Math.cos(actual.lat * r) * Math.cos(lat * r) * Math.sin((lon - actual.lon) * r / 2) ** 2;
  return 12742000 * Math.asin(Math.min(1, Math.sqrt(h)));
}

test("coordinate-search modules retain exact upstream bytes and source license", async () => {
  for (const [name, length, blob, sha256] of sourceFiles) {
    const bytes = await readFile(new URL(name, vendor));
    assert.equal(bytes.length, length, `${name}: UTF-8 bytes`);
    assert.equal(createHash("sha256").update(bytes).digest("hex"), sha256, `${name}: source digest`);
    assert.equal(createHash("sha1").update(`blob ${bytes.length}\0`).update(bytes).digest("hex"), blob, `${name}: upstream Git blob`);
  }
  const license = await readFile(new URL("LICENSE", vendor));
  assert.equal(createHash("sha256").update(license).digest("hex"), "b231bb38e2d4eab741643126087cbe9df2b58e2f2e5abf27ad613d05f52b01ca");
  assert.match(license.toString("utf8"), /Copyright \(c\) 2026 Bilawal Sidhu/);
});

test("decimal coordinates and two-dimensional WGS84 geo URIs retain their exact meaning", () => {
  for (const query of ["47.61, -122.33", "47.61 N, 122.33 W", "W 122.33, N 47.61", "geo:47.61,-122.33;crs=wgs84"]) {
    nearDegrees(parseCoordinateQuery(query), 47.61, -122.33);
  }
  nearDegrees(parseCoordinateQuery("0, 0"), 0, 0);
  nearDegrees(parseCoordinateQuery("geo:90,180"), 90, 180);
  nearDegrees(parseCoordinateQuery("geo:-90,-180;crs=wgs84"), -90, -180);
  assert.equal(parseCoordinateQuery("47.61, -122.33").label, "47.6100° N, 122.3300° W");
});

test("marked degrees/minutes/seconds preserve hemisphere, order and fractional meaning", () => {
  for (const query of ['40°26\'46"N, 79°58\'56"W', "40° 26′ 46″ N 79° 58′ 56″ W", 'W 79°58\'56" N 40°26\'46"']) {
    nearDegrees(parseCoordinateQuery(query), 40.44611111111111, -79.98222222222222);
  }
  nearDegrees(parseCoordinateQuery("N 40°26.767' W 79°58.933'"), 40.44611666666667, -79.98221666666667);
  nearDegrees(parseCoordinateQuery('-33°51\'24", 151°12\'55"'), -33.85666666666667, 151.21527777777777);
  nearDegrees(parseCoordinateQuery('90°0\'0"N, 180°0\'0"E'), 90, 180);
});

// Fixed external-oracle outputs from the pinned upstream
// src/search/gridReference.test.mjs (pyproj and mgrs reference conversions).
// Expected coordinates are not computed with the parser being tested.
const gridFixtures = [
  ["18TWL8565011369", 40.7488215, -73.9854319, "18T 585651 4511369", 40.748817, -73.985428],
  ["56HLH3490052290", -33.8567842, 151.2152996, "56H 334900 6252291", -33.856784, 151.215297],
  ["33XWG1427883355", 78.2232003, 15.6266906, "33X 514279 8683355", 78.2232, 15.6267],
  ["32VKN9747700830", 60.392994, 5.3241531, "32V 297477 6700830", 60.39299, 5.32415],
  ["01CDM4324728161", -79.8999987, -179.9000186, "1C 443248 1128161", -79.9, -179.9],
  ["60XWU3439017795", 83.8999979, 179.899971, "60X 534391 9317796", 83.9, 179.9],
  ["17MQV8185780012", -0.1806554, -78.4678355, "17M 781858 9980013", -0.180653, -78.467834],
  ["54SUD1748374870", 34.9999987, 138.9999956, "54S 317484 3874871", 35, 139],
];

test("UTM and MGRS agree with reference locations across hemispheres and exceptional zones", () => {
  for (const [mgrs, mgrsLat, mgrsLon, utm, utmLat, utmLon] of gridFixtures) {
    assert.ok(metresBetween(parseGridReference(mgrs), mgrsLat, mgrsLon) < 1, mgrs);
    assert.ok(metresBetween(parseCoordinateQuery(mgrs), mgrsLat, mgrsLon) < 1, `${mgrs}: search entry`);
    assert.ok(metresBetween(parseGridReference(utm), utmLat, utmLon) < 1, utm);
    assert.ok(metresBetween(parseCoordinateQuery(utm), utmLat, utmLon) < 1, `${utm}: search entry`);
  }
  // By UTM's definition, 500,000 m easting at the equator lies on the
  // zone's central meridian. These identities need no reference converter.
  for (const [query, lon] of [["1N 500000 0", -177], ["31N 500000 0", 3], ["60N 500000 0", 177]]) {
    nearDegrees(parseGridReference(query), 0, lon);
  }
});

test("MGRS spacing, resolution and antimeridian references preserve the identified square", () => {
  for (const query of ["18TWL8565011369", "18T WL 8565011369", "18T WL 85650 11369", "18twl8565011369"]) {
    assert.ok(metresBetween(parseCoordinateQuery(query), 40.7488215, -73.9854319) < 1, query);
  }
  assert.ok(metresBetween(parseGridReference("18TWL856113"), 40.74882, -73.98543) < 71, "100 m square center");
  assert.ok(metresBetween(parseGridReference("18TWL85651136"), 40.74882, -73.98543) < 8, "10 m square center");
  for (const query of ["1HBD1970044714", "60TYQ364873", "1QAC860142"]) {
    const point = parseGridReference(query);
    assert.ok(point, query);
    assert.ok(Math.abs(point.lon) > 179.99 && Math.abs(point.lon) <= 180, `${query}: antimeridian`);
  }
});

test("upstream UTM S favors the northern latitude band when hemisphere readings are ambiguous", () => {
  // An inherited upstream convention, not a resolution of a Dispatch
  // operator's ambiguous request. The Dispatch caller must guard it.
  const ambiguous = parseCoordinateQuery("54S 383000 3950000");
  assert.ok(ambiguous.lat > 35 && ambiguous.lat < 36);
  assert.ok(ambiguous.lon > 139 && ambiguous.lon < 140);
  assert.ok(metresBetween(parseCoordinateQuery("56S 334900 6252291"), -33.856784, 151.215297) < 1, "otherwise S means southern hemisphere");
  const north = parseCoordinateQuery("33N 500000 4500000");
  assert.ok(north.lat > 40 && north.lat < 41, "N also accepts northern hemisphere outside band N");
  assert.ok(Math.abs(north.lon - 15) < 1e-9);
});

test("full plus codes resolve reference cell centers without implying observed point accuracy", () => {
  // Open Location Code decoding fixtures, also retained in the pinned
  // upstream gridReference.test.mjs. All expected values are area centers.
  for (const [code, lat, lon] of [
    ["849VCWC8+R9", 37.4220625, -122.0840625], ["7FG49Q00+", 20.375, 2.775],
    ["7FG49QCJ+2VX", 20.3701125, 2.782234375], ["CR4389W6+MV36X2V", 72.34663418, 141.3621622924805],
    ["2Q3P6CPJ+Q3H7HQ7", -88.76306733999999, 134.430234069824], ["9R000000+", 60, 150],
  ]) {
    nearDegrees(parsePlusCode(code), lat, lon);
    nearDegrees(parseCoordinateQuery(code), lat, lon);
  }
  nearDegrees(parseCoordinateQuery(" 849vcwc8+r9 "), 37.4220625, -122.0840625);
});

test("malformed, contradictory and context-dependent searches are refused without guessing", () => {
  const refused = [
    "Seattle", "91, 12", "12, -181", "12junk, 34oops", "-40N, 74W", "N40W, 74", "N 40, N 74",
    "geo:12,34,200", "geo:12,34;u=100", "geo:12,34#private", "geo:12,34?place=private", "geo:12,34;crs=unknown", "1e3, 2", ", 34",
    '40°60\'0"N, 79°0\'0"W', '40°26\'60"N, 79°0\'0"W', '40°26.5\'46"N, 79°0\'0"W',
    '-40°26\'46"N, 79°0\'0"W', 'N 40°26\'46"N, 79°0\'0"W', '91°0\'0"N, 79°0\'0"W',
    "40 26 46 N 79 58 56 W", "40 N 74", "18TWL856501136", "18T WL 8565 11369", "18IWL8565011369",
    "18TIL8565011369", "18TAL8565011369", "61T WL 85650 11369", "0T WL 85650 11369", "18Z WL 85650 11369",
    "18T 58565 4511369", "18T 585651 4511369 extra", "32X 500000 8700000", "34X NG 123 456", "36XNG123456",
    "18TWL8511", "18T WL 85 11", "18TWL81", "18TWL", "18T SL 50000 50000", "18t wl 85650 11369",
    "1 JAN 2023", "1 JAN 2023 1200", "15 SEP 2024 0630", "3 USA 12", "20 KPH 1000",
    "CWC8+R9", "CWC8+R9 Mountain View", "8FWC2345+G", "8FWC2300+G6", "8FWC2345+G6+", "8FWC2_45+G6", "+", "",
  ];
  for (const query of refused) assert.equal(parseCoordinateQuery(query), null, query);
});

test("coordinate-search entry and helpers refuse non-strings without throwing", () => {
  for (const value of [null, undefined, 42, {}, [], ["40", "74"]]) {
    assert.equal(parseCoordinateQuery(value), null);
    assert.equal(parseGridReference(value), null);
    assert.equal(parsePlusCode(value), null);
  }
});
