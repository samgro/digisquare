import { describe, expect, it } from "vitest";
import {
  largeVenueSearchCircle,
  mergeNearbyResults,
  MINIMUM_LARGE_VENUE_SEARCH_RADIUS,
  shouldSearchByDistance,
  type PlaceCandidate,
} from "./places-search.js";

function candidate(id: string): PlaceCandidate {
  return { id, name: id } as PlaceCandidate;
}

describe("mergeNearbyResults", () => {
  it("keeps nearest-first order and drops large venues already listed", () => {
    const merged = mergeNearbyResults([
      [candidate("cafe"), candidate("park")],
      [candidate("airport"), candidate("park")],
    ]);
    expect(merged.map((place) => place.id)).toEqual(["cafe", "park", "airport"]);
  });

  it("is empty with no results", () => {
    expect(mergeNearbyResults([[], []])).toEqual([]);
  });
});

describe("shouldSearchByDistance", () => {
  it("skips the nearest-first search for a cell-tower grade fix", () => {
    expect(shouldSearchByDistance(undefined)).toBe(true);
    expect(shouldSearchByDistance(42)).toBe(true);
    expect(shouldSearchByDistance(1000)).toBe(true);
    expect(shouldSearchByDistance(1001)).toBe(false);
  });
});

describe("largeVenueSearchCircle", () => {
  it("reaches at least two kilometers", () => {
    expect(largeVenueSearchCircle({ latitude: 1, longitude: 2, radius: 500 }).radius).toBe(
      MINIMUM_LARGE_VENUE_SEARCH_RADIUS,
    );
    expect(largeVenueSearchCircle({ latitude: 1, longitude: 2, radius: 5000 }).radius).toBe(5000);
  });
});
