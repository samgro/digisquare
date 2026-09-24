import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";
import { describe, expect, it } from "vitest";
import { decodeWkbHex } from "./wkb.js";
import {
  extentFamily,
  familyAcceptsCategory,
  namesMatch,
  normalizedName,
  parseOvertureExtent,
  polygonsContain,
  type OvertureExtentFeature,
} from "./overture-extents.js";

interface SampleRow {
  id: string;
  geometry: { __wkb_hex__: string };
  names?: { primary?: string | null } | null;
  subtype?: string;
  class?: string;
}

const samples = JSON.parse(
  readFileSync(
    path.join(path.dirname(fileURLToPath(import.meta.url)), "../../test/fixtures/overture/release-2026-09-23-samples.json"),
    "utf-8",
  ),
) as { land_use: SampleRow[]; infrastructure: SampleRow[] };

function featureFromSample(row: SampleRow, decode = true): OvertureExtentFeature {
  return {
    id: row.id,
    geometry: decode ? decodeWkbHex(row.geometry.__wkb_hex__) : null,
    properties: { subtype: row.subtype, class: row.class, names: row.names },
  };
}

describe("parseOvertureExtent", () => {
  it("turns Golden Gate Park's land_use polygon into a park extent", () => {
    const row = samples.land_use.find((candidate) => candidate.names?.primary === "Golden Gate Park")!;
    const extent = parseOvertureExtent(featureFromSample(row));
    expect(extent?.family).toBe("park");
    expect(extent?.name).toBe("Golden Gate Park");
    expect(extent?.polygons).toHaveLength(1);
    // The de Young Museum is inside the park; Ocean Beach is not.
    expect(polygonsContain(extent!.polygons, -122.4686, 37.7715)).toBe(true);
    expect(polygonsContain(extent!.polygons, -122.5115, 37.7600)).toBe(false);
  });

  it("turns SFO's infrastructure polygon into an airport extent that contains Terminal 2", () => {
    const row = samples.infrastructure.find((candidate) => candidate.class === "international_airport")!;
    const extent = parseOvertureExtent(featureFromSample(row));
    expect(extent?.family).toBe("airport");
    expect(polygonsContain(extent!.polygons, -122.3838, 37.6165)).toBe(true);
  });

  it("ignores a taxiway, an unnamed feature and a marine sanctuary", () => {
    const taxiway = samples.infrastructure.find((candidate) => candidate.class === "taxiway")!;
    expect(parseOvertureExtent(featureFromSample(taxiway))).toBeNull();

    const park = samples.land_use.find((candidate) => candidate.names?.primary === "Golden Gate Park")!;
    expect(parseOvertureExtent({ ...featureFromSample(park), properties: { subtype: "park", class: "park", names: null } })).toBeNull();

    const sanctuary = samples.land_use.find((candidate) => candidate.names?.primary?.includes("Sanctuary"))!;
    expect(extentFamily(sanctuary.subtype, sanctuary.class)).toBeNull();
    expect(parseOvertureExtent(featureFromSample(sanctuary, false))).toBeNull();
  });

  it("wraps a single polygon and accepts a multipolygon", () => {
    const square: [number, number][] = [[0, 0], [1, 0], [1, 1], [0, 1], [0, 0]];
    const single = parseOvertureExtent({ id: "a", geometry: { type: "Polygon", coordinates: [square] }, properties: { subtype: "park", class: "park", names: { primary: "Square" } } });
    expect(single?.polygons).toEqual([[square]]);
    const multi = parseOvertureExtent({ id: "b", geometry: { type: "MultiPolygon", coordinates: [[square], [square]] }, properties: { subtype: "park", class: "park", names: { primary: "Squares" } } });
    expect(multi?.polygons).toHaveLength(2);
  });
});

describe("families", () => {
  it("maps classes and the winter sports subtype", () => {
    expect(extentFamily("recreation", "stadium")).toBe("stadium");
    expect(extentFamily("winter_sports", "downhill")).toBe("ski");
    expect(extentFamily("developed", "retail")).toBeNull();
  });

  it("accepts the categories and suffixes each family may attach to", () => {
    expect(familyAcceptsCategory("stadium", "stadium_arena")).toBe(true);
    expect(familyAcceptsCategory("stadium", "baseball_stadium")).toBe(true);
    expect(familyAcceptsCategory("stadium", "coffee_shop")).toBe(false);
    expect(familyAcceptsCategory("airport", "airport")).toBe(true);
    expect(familyAcceptsCategory("park", "museum")).toBe(false);
  });
});

describe("names", () => {
  it("normalizes and matches names loosely", () => {
    expect(normalizedName("The de Young Museum")).toBe("de young museum");
    expect(namesMatch("Golden Gate Park", "golden gate park")).toBe(true);
    expect(namesMatch("San Francisco International Airport", "SFO")).toBe(false);
    expect(namesMatch("Levi's Stadium", "Levis Stadium")).toBe(true);
  });
});

describe("polygonsContain", () => {
  it("respects holes", () => {
    const outer: [number, number][] = [[0, 0], [10, 0], [10, 10], [0, 10], [0, 0]];
    const hole: [number, number][] = [[4, 4], [6, 4], [6, 6], [4, 6], [4, 4]];
    expect(polygonsContain([[outer, hole]], 2, 2)).toBe(true);
    expect(polygonsContain([[outer, hole]], 5, 5)).toBe(false);
    expect(polygonsContain([[outer, hole]], 11, 5)).toBe(false);
  });
});
