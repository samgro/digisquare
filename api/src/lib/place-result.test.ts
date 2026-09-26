import { describe, expect, it } from "vitest";
import { displayRegion, formatAddress, toPlaceResult } from "./place-result.js";
import type { PlaceCandidate } from "./places-search.js";

function candidate(overrides: Partial<PlaceCandidate> = {}): PlaceCandidate {
  return {
    id: "a2c1f0e4-6b7d-4e3a-9c1f-1d2e3f4a5b6c",
    source: "overture",
    overtureId: "08f2830828d3a8db0344a5b5c2fd1a3e",
    googlePlaceId: null,
    foursquareVenueId: null,
    name: "Costco Wholesale",
    primaryType: "wholesale_store",
    types: ["wholesale_store", "grocery_store"],
    categoryName: null,
    addressStreet: "450 10th St",
    addressLocality: "San Francisco",
    addressRegion: "US-CA",
    addressPostcode: "94103",
    addressCountry: "US",
    latitude: 37.7706,
    longitude: -122.4108,
    confidence: 0.93,
    website: "https://www.costco.com",
    phone: "+1 415-626-4388",
    basicCategory: "warehouse_club_store",
    taxonomyHierarchy: ["shopping", "warehouse_club_store"],
    sourceDataset: "meta",
    sourceUpdatedAt: new Date("2026-09-14T00:00:00.000Z"),
    operatingStatus: "open",
    providerCount: 3,
    prior: 2,
    createdByUserId: null,
    extentOvertureId: null,
    extentAreaSquareMeters: null,
    isPrivate: false,
    lastSeenRelease: null,
    retiredAt: null,
    extentGeoJson: null,
    extentSouth: null,
    extentWest: null,
    extentNorth: null,
    extentEast: null,
    distanceMeters: null,
    createdAt: new Date("2026-09-01T00:00:00.000Z"),
    updatedAt: new Date("2026-09-01T00:00:00.000Z"),
    checkinCount: 3,
    ...overrides,
  };
}

describe("formatAddress", () => {
  it("joins the parts the way Google's formatted address read", () => {
    expect(formatAddress(candidate())).toBe("450 10th St, San Francisco, CA 94103, US");
  });

  it("skips missing parts without leaving separators behind", () => {
    expect(
      formatAddress(candidate({ addressStreet: null, addressPostcode: null, addressCountry: null })),
    ).toBe("San Francisco, CA");
    expect(formatAddress(candidate({ addressRegion: null }))).toBe(
      "450 10th St, San Francisco, 94103, US",
    );
  });

  it("is null when there is no address at all", () => {
    expect(
      formatAddress(
        candidate({
          addressStreet: null,
          addressLocality: null,
          addressRegion: null,
          addressPostcode: null,
          addressCountry: null,
        }),
      ),
    ).toBeNull();
  });
});

describe("displayRegion", () => {
  it("drops the country prefix from an ISO 3166-2 code", () => {
    expect(displayRegion("US-CA")).toBe("CA");
    expect(displayRegion("GB-ENG")).toBe("ENG");
  });

  it("keeps anything a user typed by hand", () => {
    expect(displayRegion("California")).toBe("California");
    expect(displayRegion(null)).toBeNull();
  });
});

describe("toPlaceResult", () => {
  it("exposes the fields the client decodes and nothing internal", () => {
    expect(toPlaceResult(candidate())).toEqual({
      id: "a2c1f0e4-6b7d-4e3a-9c1f-1d2e3f4a5b6c",
      source: "overture",
      name: "Costco Wholesale",
      address: "450 10th St, San Francisco, CA 94103, US",
      street: "450 10th St",
      locality: "San Francisco",
      region: "US-CA",
      postcode: "94103",
      country: "US",
      location: { latitude: 37.7706, longitude: -122.4108 },
      extent: null,
      distanceMeters: null,
      types: ["wholesale_store", "grocery_store"],
      primaryType: "wholesale_store",
      basicCategory: "warehouse_club_store",
      categoryName: null,
      checkinCount: 3,
      prior: 2,
      isPrivate: false,
      retired: false,
      website: "https://www.costco.com",
      phone: "+1 415-626-4388",
    });
  });

  it("maps a legacy row without a pin to a null location", () => {
    const result = toPlaceResult(
      candidate({ source: "google", overtureId: null, googlePlaceId: "ChIJx", latitude: null, longitude: null }),
    );
    expect(result.location).toBeNull();
    expect(result.source).toBe("google");
  });
});
