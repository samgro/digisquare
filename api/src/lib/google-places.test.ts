import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
  LARGE_VENUE_TYPES,
  autocompletePlaceIdentifiers,
  fetchPlaceDetails,
  mergeNearbyResults,
  searchAutocomplete,
  searchNearby,
  searchNearbyCandidates,
  searchText,
} from "./google-places.js";
import { stubFetch, type StubbedFetch } from "../../test/helpers/stub-fetch.js";
import { loadGoogleFixture } from "../../test/helpers/fixtures.js";

const LOCATION = { latitude: 37.7749, longitude: -122.4194, radius: 1500 };

let stub: StubbedFetch;

beforeEach(() => {
  vi.stubEnv("GOOGLE_PLACES_API_KEY", "test-api-key");
});

afterEach(() => {
  stub?.restore();
});

describe("searchText", () => {
  it("posts the query biased toward the point and returns the places", async () => {
    stub = stubFetch([
      { match: "places:searchText", json: loadGoogleFixture("search-nearby.json") },
    ]);

    const results = await searchText({ query: "Blue Bottle", ...LOCATION });

    expect(stub.calls).toHaveLength(1);
    expect(stub.calls[0].url).toBe("https://places.googleapis.com/v1/places:searchText");
    expect(stub.calls[0].body).toEqual({
      textQuery: "Blue Bottle",
      maxResultCount: 5,
      locationBias: {
        circle: { center: { latitude: 37.7749, longitude: -122.4194 }, radius: 1500 },
      },
    });
    expect(results).toHaveLength(2);
  });
});

describe("searchNearby", () => {
  it("posts to searchNearby with the places.-prefixed field mask", async () => {
    stub = stubFetch([
      { match: "places:searchNearby", json: loadGoogleFixture("search-nearby.json") },
    ]);

    const results = await searchNearby(LOCATION);

    expect(stub.calls).toHaveLength(1);
    const call = stub.calls[0];
    expect(call.method).toBe("POST");
    expect(call.url).toBe("https://places.googleapis.com/v1/places:searchNearby");
    expect(call.headers["x-goog-api-key"]).toBe("test-api-key");
    expect(call.headers["x-goog-fieldmask"]).toBe(
      "places.id,places.displayName,places.formattedAddress,places.location,places.viewport,places.types,places.primaryType,places.rating,places.userRatingCount",
    );
    expect(call.body).toEqual({
      maxResultCount: 20,
      rankPreference: "POPULARITY",
      locationRestriction: {
        circle: { center: { latitude: 37.7749, longitude: -122.4194 }, radius: 1500 },
      },
    });
    expect(results).toHaveLength(2);
  });

  it("returns an empty array when the response has no places key", async () => {
    stub = stubFetch([{ match: "places:searchNearby", json: {} }]);

    const results = await searchNearby(LOCATION);

    expect(results).toEqual([]);
  });

  it("sends the requested rank preference", async () => {
    stub = stubFetch([{ match: "places:searchNearby", json: {} }]);

    await searchNearby({ ...LOCATION, rankPreference: "DISTANCE" });

    expect((stub.calls[0].body as { rankPreference: string }).rankPreference).toBe("DISTANCE");
  });
});

function isRankedBy(rankPreference: string) {
  return (body: unknown) => (body as { rankPreference?: string }).rankPreference === rankPreference;
}

describe("searchNearbyCandidates", () => {
  const nearest = { places: [{ id: "near-1" }, { id: "shared" }, { id: "near-2" }] };
  const popular = { places: [{ id: "popular-1" }, { id: "shared" }, { id: "popular-2" }] };

  it("runs a distance search at the given radius and a large-venue search at least 2000 m wide", async () => {
    stub = stubFetch([
      { match: "places:searchNearby", matchBody: isRankedBy("DISTANCE"), json: nearest },
      { match: "places:searchNearby", matchBody: isRankedBy("POPULARITY"), json: popular },
    ]);

    await searchNearbyCandidates({ ...LOCATION, accuracy: 30 });

    expect(stub.calls).toHaveLength(2);
    const bodies = stub.calls.map(
      (call) =>
        call.body as {
          rankPreference: string;
          includedTypes?: string[];
          locationRestriction: { circle: { radius: number } };
        },
    );
    expect(bodies.map((body) => body.rankPreference).sort()).toEqual(["DISTANCE", "POPULARITY"]);
    const distance = bodies.find((body) => body.rankPreference === "DISTANCE");
    const largeVenues = bodies.find((body) => body.rankPreference === "POPULARITY");
    expect(distance?.locationRestriction.circle.radius).toBe(1500);
    expect(distance?.includedTypes).toBeUndefined();
    expect(largeVenues?.locationRestriction.circle.radius).toBe(2000);
    expect(largeVenues?.includedTypes).toEqual([...LARGE_VENUE_TYPES]);
  });

  it("keeps a caller radius wider than 2000 m for the large-venue search too", async () => {
    stub = stubFetch([{ match: "places:searchNearby", json: {} }]);

    await searchNearbyCandidates({ ...LOCATION, radius: 4000 });

    const radii = stub.calls.map(
      (call) => (call.body as { locationRestriction: { circle: { radius: number } } }).locationRestriction.circle.radius,
    );
    expect(radii).toEqual([4000, 4000]);
  });

  it("lists nearest places first and drops duplicates from the large-venue search", async () => {
    stub = stubFetch([
      { match: "places:searchNearby", matchBody: isRankedBy("DISTANCE"), json: nearest },
      { match: "places:searchNearby", matchBody: isRankedBy("POPULARITY"), json: popular },
    ]);

    const results = await searchNearbyCandidates({ ...LOCATION, accuracy: 30 });

    expect(results.map((place) => place.id)).toEqual([
      "near-1",
      "shared",
      "near-2",
      "popular-1",
      "popular-2",
    ]);
  });

  it("skips the distance search when the fix is coarser than 1000 m", async () => {
    stub = stubFetch([
      { match: "places:searchNearby", matchBody: isRankedBy("POPULARITY"), json: popular },
    ]);

    const results = await searchNearbyCandidates({ ...LOCATION, accuracy: 3000 });

    expect(stub.calls).toHaveLength(1);
    expect(results.map((place) => place.id)).toEqual(["popular-1", "shared", "popular-2"]);
  });

  it("still runs the distance search when no accuracy was reported", async () => {
    stub = stubFetch([{ match: "places:searchNearby", json: {} }]);

    await searchNearbyCandidates(LOCATION);

    expect(stub.calls).toHaveLength(2);
  });

  it("returns the surviving search when the other one fails", async () => {
    vi.spyOn(console, "error").mockImplementation(() => {});
    stub = stubFetch([
      { match: "places:searchNearby", matchBody: isRankedBy("DISTANCE"), status: 500, text: "boom" },
      { match: "places:searchNearby", matchBody: isRankedBy("POPULARITY"), json: popular },
    ]);

    const results = await searchNearbyCandidates({ ...LOCATION, accuracy: 30 });

    expect(results.map((place) => place.id)).toEqual(["popular-1", "shared", "popular-2"]);
    expect(console.error).toHaveBeenCalledTimes(1);
  });

  it("throws when both searches fail", async () => {
    vi.spyOn(console, "error").mockImplementation(() => {});
    stub = stubFetch([{ match: "places:searchNearby", status: 500, text: "boom" }]);

    await expect(searchNearbyCandidates({ ...LOCATION, accuracy: 30 })).rejects.toThrow(
      "Google Places API error (500): boom",
    );
  });
});

describe("mergeNearbyResults", () => {
  it("is a stable, first-wins merge", () => {
    const merged = mergeNearbyResults([
      [{ id: "a", primaryType: "first" }, { id: "b" }],
      [{ id: "b", primaryType: "second" }, { id: "c" }],
    ]);

    expect(merged).toEqual([{ id: "a", primaryType: "first" }, { id: "b" }, { id: "c" }]);
  });
});

describe("autocompletePlaceIdentifiers", () => {
  it("posts to places:autocomplete with input and locationBias, not textQuery/locationRestriction", async () => {
    stub = stubFetch([
      { match: "places:autocomplete", json: loadGoogleFixture("autocomplete-cos.json") },
    ]);

    await autocompletePlaceIdentifiers({ query: "cos", ...LOCATION });

    const call = stub.calls[0];
    expect(call.method).toBe("POST");
    expect(call.url).toBe("https://places.googleapis.com/v1/places:autocomplete");
    expect(call.body).toEqual({
      input: "cos",
      locationBias: {
        circle: { center: { latitude: 37.7749, longitude: -122.4194 }, radius: 1500 },
      },
    });
  });

  it("skips queryPrediction entries that have no placeId", async () => {
    stub = stubFetch([
      { match: "places:autocomplete", json: loadGoogleFixture("autocomplete-cos.json") },
    ]);

    const placeIdentifiers = await autocompletePlaceIdentifiers({ query: "cos", ...LOCATION });

    expect(placeIdentifiers).toEqual([
      "ChIJcos00000COSTCO",
      "ChIJcos00001COSBAR",
      "ChIJcos00002COSCLOTHING",
    ]);
  });

  it("returns an empty array when suggestions is absent", async () => {
    stub = stubFetch([
      { match: "places:autocomplete", json: loadGoogleFixture("autocomplete-empty.json") },
    ]);

    expect(await autocompletePlaceIdentifiers({ query: "zzz", ...LOCATION })).toEqual([]);
  });
});

describe("fetchPlaceDetails", () => {
  it("GETs places/{id} with an unprefixed field mask", async () => {
    stub = stubFetch([
      { match: "/places/ChIJcos00000COSTCO", json: loadGoogleFixture("details-costco.json") },
    ]);

    const place = await fetchPlaceDetails("ChIJcos00000COSTCO");

    const call = stub.calls[0];
    expect(call.method).toBe("GET");
    expect(call.url).toBe("https://places.googleapis.com/v1/places/ChIJcos00000COSTCO");
    // Regression guard: the search field mask is `places.`-prefixed and
    // Google rejects that prefix on the details endpoint with a 400.
    expect(call.headers["x-goog-fieldmask"]).toBe(
      "id,displayName,formattedAddress,location,viewport,types,primaryType,rating,userRatingCount",
    );
    expect(call.headers["x-goog-fieldmask"]).not.toContain("places.");
    expect(place.id).toBe("ChIJcos00000COSTCO");
  });
});

describe("searchAutocomplete", () => {
  it("preserves autocomplete order even when lookups resolve out of order", async () => {
    stub = stubFetch([
      { match: "places:autocomplete", json: loadGoogleFixture("autocomplete-cos.json") },
      {
        match: "/places/ChIJcos00000COSTCO",
        json: loadGoogleFixture("details-costco.json"),
        delayMilliseconds: 30,
      },
      { match: "/places/ChIJcos00001COSBAR", json: loadGoogleFixture("details-cos-bar.json") },
      {
        match: "/places/ChIJcos00002COSCLOTHING",
        json: loadGoogleFixture("details-cos-clothing.json"),
      },
    ]);

    const places = await searchAutocomplete({ query: "cos", ...LOCATION });

    expect(places.map((place) => place.id)).toEqual([
      "ChIJcos00000COSTCO",
      "ChIJcos00001COSBAR",
      "ChIJcos00002COSCLOTHING",
    ]);
  });

  it("drops a single failed detail lookup and returns the rest", async () => {
    vi.spyOn(console, "error").mockImplementation(() => {});
    stub = stubFetch([
      { match: "places:autocomplete", json: loadGoogleFixture("autocomplete-cos.json") },
      { match: "/places/ChIJcos00000COSTCO", json: loadGoogleFixture("details-costco.json") },
      { match: "/places/ChIJcos00001COSBAR", status: 404, text: "not found" },
      {
        match: "/places/ChIJcos00002COSCLOTHING",
        json: loadGoogleFixture("details-cos-clothing.json"),
      },
    ]);

    const places = await searchAutocomplete({ query: "cos", ...LOCATION });

    expect(places.map((place) => place.id)).toEqual([
      "ChIJcos00000COSTCO",
      "ChIJcos00002COSCLOTHING",
    ]);
    expect(console.error).toHaveBeenCalledTimes(1);
  });

  it("throws when every detail lookup fails", async () => {
    stub = stubFetch([
      { match: "places:autocomplete", json: loadGoogleFixture("autocomplete-cos.json") },
      { match: "/places/ChIJcos", status: 500, text: "detail boom" },
    ]);
    vi.spyOn(console, "error").mockImplementation(() => {});

    await expect(searchAutocomplete({ query: "cos", ...LOCATION })).rejects.toThrow(
      /Google Places API error \(500\)/,
    );
  });

  it("throws with the exact error format when autocomplete itself fails", async () => {
    stub = stubFetch([
      { match: "places:autocomplete", status: 500, text: "upstream boom" },
    ]);

    await expect(searchAutocomplete({ query: "cos", ...LOCATION })).rejects.toThrow(
      "Google Places API error (500): upstream boom",
    );
  });

  it("throws immediately when the API key is missing, without calling fetch", async () => {
    vi.stubEnv("GOOGLE_PLACES_API_KEY", "");
    stub = stubFetch([]);

    await expect(searchAutocomplete({ query: "cos", ...LOCATION })).rejects.toThrow(
      "GOOGLE_PLACES_API_KEY is not set",
    );
    expect(stub.calls).toHaveLength(0);
  });

  it("returns an empty array and fetches no details when nothing matches", async () => {
    stub = stubFetch([
      { match: "places:autocomplete", json: loadGoogleFixture("autocomplete-empty.json") },
    ]);

    const places = await searchAutocomplete({ query: "zzz", ...LOCATION });

    expect(places).toEqual([]);
    expect(stub.calls).toHaveLength(1);
  });

  it("caps detail lookups at the five predictions Google returns", async () => {
    const suggestions = Array.from({ length: 7 }, (_, index) => ({
      placePrediction: { placeId: `ChIJsynthetic${index}` },
    }));
    stub = stubFetch([
      { match: "places:autocomplete", json: { suggestions } },
      { match: "/places/ChIJsynthetic", json: { id: "ChIJsynthetic" } },
    ]);

    await searchAutocomplete({ query: "cos", ...LOCATION });

    const detailCalls = stub.calls.filter((call) => call.url.includes("/places/ChIJsynthetic"));
    expect(detailCalls).toHaveLength(5);
  });
});
