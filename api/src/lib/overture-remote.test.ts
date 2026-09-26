import { beforeAll, describe, expect, it } from "vitest";
import { loadOvertureSamples, writeSampleRelease } from "../../test/helpers/overture-parquet.js";
import { parseOverturePlace } from "./overture.js";
import { parseOvertureExtent } from "./overture-extents.js";
import { CATEGORY_BOOST } from "./place-quality.js";
import {
  fetchBridgeMatches,
  fetchCityContaining,
  fetchExtentFeatures,
  fetchPlaceFeatures,
  type OvertureSource,
} from "./overture-remote.js";

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
      basicCategory: "coffee_shop",
      taxonomyHierarchy: ["food_and_drink", "non_alcoholic_beverage_venue", "coffee_shop"],
      sourceDataset: "meta",
      sourceUpdatedAt: new Date("2026-09-14T00:00:00.000Z"),
      operatingStatus: null,
      prior: CATEGORY_BOOST,
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
    // The query keeps only the polygon kinds that can be grounds, so the
    // taxiway never comes back and every row parses.
    expect(features.length).toBe(extents.length);
    expect(features.map((feature) => feature.properties?.names?.primary)).not.toContain("L");
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

describe("fetchBridgeMatches", () => {
  it("counts distinct providers per place and maps Foursquare records to places", async () => {
    const [blueBottle, illy] = loadOvertureSamples().places.map((row) => row.id) as [string, string];
    const matches = await fetchBridgeMatches(
      source,
      [blueBottle, illy, "not-in-this-release"],
      ["4b8c1a2bf964a52056af32e3", "4a5b1d2ef964a520b5b91fe3", "unknown-record"],
    );
    expect(matches.providerCounts).toEqual(
      new Map([
        [blueBottle, 3],
        [illy, 1],
      ]),
    );
    expect(matches.overtureIdsByFoursquareRecord).toEqual(
      new Map([
        ["4b8c1a2bf964a52056af32e3", "00000000-1111-2222-3333-444444444444"],
        ["4a5b1d2ef964a520b5b91fe3", blueBottle],
      ]),
    );
  });

  it("copes with nothing to ask about", async () => {
    const matches = await fetchBridgeMatches(source, [], []);
    expect(matches.providerCounts.size).toBe(0);
    expect(matches.overtureIdsByFoursquareRecord.size).toBe(0);
  });
});
