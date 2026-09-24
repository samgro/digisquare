import { beforeAll, describe, expect, it } from "vitest";
import { loadOvertureSamples, writeSampleRelease } from "../../test/helpers/overture-parquet.js";
import { parseOverturePlace } from "./overture.js";
import { parseOvertureExtent } from "./overture-extents.js";
import { fetchCityContaining, fetchExtentFeatures, fetchPlaceFeatures, type OvertureSource } from "./overture-remote.js";

const SOMA = { west: -122.41, south: 37.78, east: -122.39, north: 37.79 };

let source: OvertureSource;

beforeAll(async () => {
  source = await writeSampleRelease();
});

describe("fetchPlaceFeatures", () => {
  it("reads release rows and turns them into features the place parser accepts", async () => {
    const batches: number[] = [];
    const rows: ReturnType<typeof parseOverturePlace>[] = [];
    const total = await fetchPlaceFeatures(
      source,
      SOMA,
      async (features) => {
        batches.push(features.length);
        rows.push(...features.map(parseOverturePlace));
      },
      1,
    );
    expect(total).toBe(loadOvertureSamples().places.length);
    expect(batches.every((size) => size === 1)).toBe(true);

    const blueBottle = rows.find((row) => row.row?.name === "Blue Bottle Coffee")?.row;
    expect(blueBottle).toMatchObject({
      overtureId: "8e266ace-78d5-493b-90a2-c4b5da8786d4",
      primaryType: "coffee_shop",
      types: ["coffee_shop", "cafe", "coffee_roastery"],
      addressStreet: "168 2nd Street",
      addressLocality: "San Francisco",
      addressRegion: "CA",
      addressCountry: "US",
      confidence: 0.954,
      website: "https://bluebottlecoffee.com/us/eng/cafes/2nd-street",
    });
    expect(blueBottle?.latitude).toBeCloseTo(37.787, 2);
    expect(rows.some((row) => row.skipped === "permanently_closed")).toBe(true);
  });

  it("filters by the bbox column", async () => {
    let seen = 0;
    await fetchPlaceFeatures(source, { west: 0, south: 0, east: 1, north: 1 }, async (features) => {
      seen += features.length;
    });
    expect(seen).toBe(0);
  });
});

describe("fetchExtentFeatures", () => {
  it("returns named land_use and infrastructure polygons that parse as extents", async () => {
    const features = await fetchExtentFeatures(source, { west: -123, south: 37, east: -122, north: 38 });
    const extents = features.map(parseOvertureExtent).filter((extent) => extent !== null);
    expect(extents.map((extent) => extent!.name)).toEqual(
      expect.arrayContaining(["Golden Gate Park", "San Francisco International Airport"]),
    );
    // Taxiways and the marine sanctuary come back as rows but are not extents.
    expect(features.length).toBeGreaterThan(extents.length);
  });
});

describe("fetchCityContaining", () => {
  it("falls back to the county for San Francisco, which has no locality", async () => {
    const city = await fetchCityContaining(source, { latitude: 37.7863, longitude: -122.4003 });
    expect(city).toMatchObject({ name: "San Francisco", subtype: "county" });
    expect(city!.bounds.west).toBeLessThan(-122.4);
    expect(city!.bounds.east).toBeGreaterThan(-122.4);
  });

  it("is null outside every division", async () => {
    expect(await fetchCityContaining(source, { latitude: 0, longitude: 0 })).toBeNull();
  });
});
