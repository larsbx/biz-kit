import { describe, expect, it } from "vitest";
import {
  PRESETS, clampRatio, closeLeaf, currentPreset, leaf, leaves, parseLayout, serialize, setPanel, setRatio, shape,
  split, splitLeaf,
} from "./layout";

const panels = new Set(["health", "services", "scripts", "configs", "dispatch", "settings"]);

describe("layout tree", () => {
  it("splits a leaf, keeping the original and adding the new panel after it", () => {
    const a = leaf("health");
    const t = splitLeaf(a, a.id, "h", "services");
    expect(shape(t)).toEqual(["h", "health", "services"]);
    expect(leaves(t)[0]).toBe(a);
    expect(a).toEqual({ t: "leaf", id: a.id, p: "health" }); // input untouched
  });

  it("closes a leaf and gives its space to the sibling, but never the last tile", () => {
    const a = leaf("health"), b = leaf("services"), c = leaf("scripts");
    const t = split("h", 0.5, a, split("v", 0.5, b, c));
    expect(shape(closeLeaf(t, b.id))).toEqual(["h", "health", "scripts"]);
    expect(shape(closeLeaf(t, a.id))).toEqual(["v", "services", "scripts"]);
    expect(closeLeaf(a, a.id)).toBe(a);
  });

  it("changes a tile's panel under a new id, so the old panel unmounts", () => {
    const a = leaf("health");
    const t = setPanel(split("h", 0.5, a, leaf("services")), a.id, "configs");
    expect(shape(t)).toEqual(["h", "configs", "services"]);
    expect(leaves(t)[0].id).not.toBe(a.id);
  });

  it("clamps ratios and shares untouched subtrees", () => {
    const left = leaf("health");
    const t = split("h", 0.5, left, leaf("services"));
    const moved = setRatio(t, t.id, 0.99);
    expect(moved.t === "split" && moved.r).toBe(clampRatio(0.99));
    expect(moved.t === "split" && moved.a).toBe(left);
    expect(clampRatio(-1)).toBe(0.15);
  });
});

describe("presets", () => {
  it("recognises a preset by arrangement, through resizes but not through splits", () => {
    const t = PRESETS[0].build();
    expect(currentPreset(t)).toBe(PRESETS[0].name);
    expect(currentPreset(setRatio(t, t.id, 0.3))).toBe(PRESETS[0].name);
    expect(currentPreset(splitLeaf(t, leaves(t)[0].id, "v", "scripts"))).toBeNull();
  });

  it("only names panels that exist and has distinct arrangements", () => {
    for (const p of PRESETS) for (const l of leaves(p.build())) expect(panels.has(l.p)).toBe(true);
    const shapes = PRESETS.map((p) => JSON.stringify(shape(p.build())));
    expect(new Set(shapes).size).toBe(shapes.length);
  });
});

describe("parseLayout", () => {
  it("round-trips a stored layout", () => {
    const t = PRESETS[2].build();
    const back = parseLayout(JSON.stringify(serialize(t)), panels)!;
    expect(shape(back)).toEqual(shape(t));
  });

  it("rejects malformed layouts and unknown panels as a whole", () => {
    expect(parseLayout(null, panels)).toBeNull();
    expect(parseLayout("not json", panels)).toBeNull();
    expect(parseLayout('{"t":"leaf","p":"gone"}', panels)).toBeNull();
    expect(parseLayout('{"t":"split","dir":"x","r":0.5,"a":{"t":"leaf","p":"health"},"b":{"t":"leaf","p":"health"}}', panels)).toBeNull();
    expect(parseLayout('{"t":"split","dir":"h","r":0.5,"a":{"t":"leaf","p":"health"},"b":{"t":"leaf","p":"gone"}}', panels)).toBeNull();
  });

  it("clamps a stored ratio", () => {
    const t = parseLayout('{"t":"split","dir":"h","r":7,"a":{"t":"leaf","p":"health"},"b":{"t":"leaf","p":"scripts"}}', panels)!;
    expect(t.t === "split" && t.r).toBe(0.85);
  });
});
