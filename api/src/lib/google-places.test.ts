import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
  autocompletePlaceIdentifiers,
  fetchPlaceDetails,
  searchAutocomplete,
  searchNearby,
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
      "places.id,places.displayName,places.formattedAddress,places.location,places.types,places.primaryType,places.rating,places.userRatingCount",
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
      "id,displayName,formattedAddress,location,types,primaryType,rating,userRatingCount",
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
