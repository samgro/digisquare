import { describe, expect, it } from "vitest";
import { overtureCategories, parseOverturePlace, type OverturePlaceFeature } from "./overture.js";
import { CATEGORY_BOOST, UNCATEGORIZED_PENALTY } from "./place-quality.js";

function feature(overrides: Partial<OverturePlaceFeature> = {}): OverturePlaceFeature {
  return {
    id: "08f2830828d3a8db0344a5b5c2fd1a3e",
    type: "Feature",
    geometry: { type: "Point", coordinates: [-122.4076, 37.7823] },
    properties: {
      theme: "places",
      type: "place",
      version: 3,
      names: { primary: "Blue Bottle Coffee" },
      taxonomy: {
        primary: "coffee_shop",
        hierarchy: ["food_and_drink", "non_alcoholic_beverage_venue", "coffee_shop"],
        alternates: ["cafe", "coffee_shop"],
      },
      basic_category: "coffee_shop",
      confidence: 0.9527,
      websites: ["https://bluebottlecoffee.com"],
      phones: ["+14152520800"],
      addresses: [
        { freeform: "66 Mint St", locality: "San Francisco", region: "US-CA", postcode: "94103", country: "us" },
      ],
      operating_status: "open",
      sources: [
        { property: "", dataset: "meta", record_id: "268437223252604", update_time: "2026-09-14T00:00:00.000Z" },
        { property: "/properties/confidence", dataset: "Overture", record_id: null, update_time: "2026-09-17T22:52:12Z" },
      ],
      ...overrides.properties,
    } as OverturePlaceFeature["properties"],
    ...overrides,
  };
}

describe("parseOverturePlace", () => {
  it("maps a current-schema feature onto a places row", () => {
    const parsed = parseOverturePlace(feature());
    expect(parsed.row).toEqual({
      source: "overture",
      overtureId: "08f2830828d3a8db0344a5b5c2fd1a3e",
      name: "Blue Bottle Coffee",
      primaryType: "coffee_shop",
      types: ["coffee_shop", "cafe"],
      basicCategory: "coffee_shop",
      taxonomyHierarchy: ["food_and_drink", "non_alcoholic_beverage_venue", "coffee_shop"],
      addressStreet: "66 Mint St",
      addressLocality: "San Francisco",
      addressRegion: "US-CA",
      addressPostcode: "94103",
      addressCountry: "US",
      latitude: 37.7823,
      longitude: -122.4076,
      confidence: 0.9527,
      website: "https://bluebottlecoffee.com",
      phone: "+14152520800",
      sourceDataset: "meta",
      sourceUpdatedAt: new Date("2026-09-14T00:00:00.000Z"),
      operatingStatus: "open",
      prior: CATEGORY_BOOST,
    });
  });

  it("takes the provider from the sources entry for the whole record", () => {
    const parsed = parseOverturePlace(
      feature({
        properties: {
          ...feature().properties,
          sources: [
            { property: "/properties/confidence", dataset: "Overture", update_time: "2026-09-17T22:52:12Z" },
            { property: null, dataset: "Microsoft", update_time: "2016-04-12" },
          ],
        },
      }),
    );
    expect(parsed.row?.sourceDataset).toBe("Microsoft");
    expect(parsed.row?.sourceUpdatedAt).toEqual(new Date("2016-04-12"));
  });

  it("scores the row from its signals", () => {
    const registryRecord = parseOverturePlace(
      feature({
        properties: {
          ...feature().properties,
          names: { primary: "Jesus Gabriel Yanez" },
          taxonomy: { primary: "health_care", hierarchy: ["health_care"], alternates: null },
          basic_category: "health_care",
          sources: [{ property: "", dataset: "BrightQuery", update_time: "2026-09-17T20:01:51.007Z" }],
        },
      }),
    );
    expect(registryRecord.row).toMatchObject({
      sourceDataset: "BrightQuery",
      taxonomyHierarchy: ["health_care"],
      // Registry feed, no real category, and a practitioner category.
      prior: -2 - 3 - 1.5,
    });
  });

  it("reads the older categories property too", () => {
    const parsed = parseOverturePlace(
      feature({
        properties: {
          names: { primary: "Costco" },
          taxonomy: null,
          categories: { primary: "wholesale_store", alternate: ["grocery_store", "wholesale_store"] },
        } as OverturePlaceFeature["properties"],
      }),
    );
    expect(parsed.row?.primaryType).toBe("wholesale_store");
    expect(parsed.row?.types).toEqual(["wholesale_store", "grocery_store"]);
  });

  it("copes with a feature that has almost nothing", () => {
    const parsed = parseOverturePlace({
      id: "x",
      geometry: { type: "Point", coordinates: [0, 0] },
      properties: { names: { primary: "Somewhere" } },
    });
    expect(parsed.row).toMatchObject({
      name: "Somewhere",
      primaryType: null,
      types: [],
      basicCategory: null,
      taxonomyHierarchy: [],
      addressStreet: null,
      addressCountry: null,
      confidence: null,
      website: null,
      phone: null,
      latitude: 0,
      longitude: 0,
      sourceDataset: null,
      sourceUpdatedAt: null,
      operatingStatus: null,
      prior: UNCATEGORIZED_PENALTY,
    });
  });

  it("skips features that cannot become a place", () => {
    expect(parseOverturePlace(feature({ id: " " })).skipped).toBe("missing_id");
    expect(
      parseOverturePlace(feature({ properties: { names: { primary: "" } } as OverturePlaceFeature["properties"] })).skipped,
    ).toBe("missing_name");
    expect(parseOverturePlace(feature({ geometry: { type: "Polygon", coordinates: [] } })).skipped).toBe(
      "missing_point",
    );
    expect(parseOverturePlace(feature({ geometry: { type: "Point", coordinates: [200, 0] } })).skipped).toBe(
      "missing_point",
    );
    expect(
      parseOverturePlace(
        feature({
          properties: { ...feature().properties, operating_status: "permanently_closed" },
        }),
      ).skipped,
    ).toBe("permanently_closed");
  });

  it("keeps a temporarily closed venue", () => {
    const parsed = parseOverturePlace(
      feature({ properties: { ...feature().properties, operating_status: "temporarily_closed" } }),
    );
    expect(parsed.row).toBeDefined();
  });

  it("clamps confidence into 0..1 and ignores a non-numeric one", () => {
    expect(parseOverturePlace(feature({ properties: { ...feature().properties, confidence: 1.4 } })).row?.confidence).toBe(1);
    expect(
      parseOverturePlace(feature({ properties: { ...feature().properties, confidence: "high" as unknown as number } })).row
        ?.confidence,
    ).toBeNull();
  });
});

describe("overtureCategories", () => {
  it("drops codes that are not category codes and leaves the hierarchy out", () => {
    const { primaryType, types } = overtureCategories(
      feature({
        properties: {
          taxonomy: { primary: "Coffee Shop", hierarchy: ["eat_and_drink"], alternates: ["cafe", "", null] },
        } as OverturePlaceFeature["properties"],
      }),
    );
    expect(primaryType).toBeNull();
    expect(types).toEqual(["cafe"]);
  });
});
