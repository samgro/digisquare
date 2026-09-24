import { describe, expect, it } from "vitest";
import { overtureCategories, parseOverturePlace, type OverturePlaceFeature } from "./overture.js";

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
        hierarchy: ["eat_and_drink", "cafe", "coffee_shop"],
        alternates: ["cafe", "coffee_shop"],
      },
      confidence: 0.9527,
      websites: ["https://bluebottlecoffee.com"],
      phones: ["+14152520800"],
      addresses: [
        { freeform: "66 Mint St", locality: "San Francisco", region: "US-CA", postcode: "94103", country: "us" },
      ],
      operating_status: "open",
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
      addressStreet: null,
      addressCountry: null,
      confidence: null,
      website: null,
      phone: null,
      latitude: 0,
      longitude: 0,
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
