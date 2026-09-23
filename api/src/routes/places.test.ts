import { Hono } from "hono";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { places } from "./places.js";
import { stubFetch, type StubbedFetch } from "../../test/helpers/stub-fetch.js";
import {
  listRankingFixtureNames,
  loadGoogleFixture,
  loadRankingFixture,
} from "../../test/helpers/fixtures.js";

const SAN_FRANCISCO = { lat: "37.7749", lng: "-122.4194" };

let stub: StubbedFetch;

beforeEach(() => {
  vi.stubEnv("GOOGLE_PLACES_API_KEY", "test-api-key");
});

afterEach(() => {
  stub?.restore();
});

function stubCosSearch() {
  stub = stubFetch([
    { match: "places:autocomplete", json: loadGoogleFixture("autocomplete-cos.json") },
    { match: "/places/ChIJcos00000COSTCO", json: loadGoogleFixture("details-costco.json") },
    { match: "/places/ChIJcos00001COSBAR", json: loadGoogleFixture("details-cos-bar.json") },
    {
      match: "/places/ChIJcos00002COSCLOTHING",
      json: loadGoogleFixture("details-cos-clothing.json"),
    },
  ]);
}

describe("GET /places?q=", () => {
  // Regression test for: q=cos returned "Cos Bar San Francisco" but not
  // "Costco". Google's old searchText endpoint matches whole tokens, so a
  // partial prefix like "cos" never matched the interior of "Costco". The
  // fix routes q= through autocomplete (prefix matching) + place details.
  it("returns Costco for a partial prefix query", async () => {
    stubCosSearch();

    const response = await places.request(
      `/?lat=${SAN_FRANCISCO.lat}&lng=${SAN_FRANCISCO.lng}&q=cos`,
    );
    expect(response.status).toBe(200);

    const body = (await response.json()) as { results: Array<{ name: string }> };
    const names = body.results.map((result) => result.name);

    expect(names).toContain("Costco Wholesale");
    expect(names).toContain("Cos Bar San Francisco");
    expect(body.results[0].name).toBe("Costco Wholesale");
  });

  it("does not call the old whole-token searchText endpoint", async () => {
    stubCosSearch();

    await places.request(`/?lat=${SAN_FRANCISCO.lat}&lng=${SAN_FRANCISCO.lng}&q=cos`);

    expect(stub.calls.some((call) => call.url.includes("searchText"))).toBe(false);
  });

  it("returns the same result shape the iOS client decodes", async () => {
    stub = stubFetch([
      {
        match: "places:autocomplete",
        json: {
          suggestions: [
            { placePrediction: { placeId: "ChIJcos00000COSTCO" } },
          ],
        },
      },
      { match: "/places/ChIJcos00000COSTCO", json: loadGoogleFixture("details-costco.json") },
    ]);

    const response = await places.request(
      `/?lat=${SAN_FRANCISCO.lat}&lng=${SAN_FRANCISCO.lng}&q=costco`,
    );
    const body = (await response.json()) as { results: unknown[] };

    expect(body.results[0]).toEqual({
      id: "ChIJcos00000COSTCO",
      name: "Costco Wholesale",
      address: "450 10th St, San Francisco, CA 94103, USA",
      location: { latitude: 37.7706, longitude: -122.4108 },
      viewport: null,
      types: ["warehouse_store", "point_of_interest", "establishment"],
      primaryType: "warehouse_store",
      rating: 4.4,
      userRatingCount: 5211,
    });
  });

  it("maps missing optional fields to null", async () => {
    stub = stubFetch([
      {
        match: "places:autocomplete",
        json: {
          suggestions: [{ placePrediction: { placeId: "ChIJcos00002COSCLOTHING" } }],
        },
      },
      {
        match: "/places/ChIJcos00002COSCLOTHING",
        json: loadGoogleFixture("details-cos-clothing.json"),
      },
    ]);

    const response = await places.request(
      `/?lat=${SAN_FRANCISCO.lat}&lng=${SAN_FRANCISCO.lng}&q=cos`,
    );
    const body = (await response.json()) as { results: Array<Record<string, unknown>> };

    expect(body.results[0]).toEqual({
      id: "ChIJcos00002COSCLOTHING",
      name: "COS",
      address: null,
      location: null,
      viewport: null,
      types: [],
      primaryType: null,
      rating: null,
      userRatingCount: null,
    });
  });

  it("radius carries through to the autocomplete location bias", async () => {
    stub = stubFetch([
      { match: "places:autocomplete", json: loadGoogleFixture("autocomplete-empty.json") },
    ]);

    await places.request(`/?lat=${SAN_FRANCISCO.lat}&lng=${SAN_FRANCISCO.lng}&q=cos`);
    const defaultCall = stub.calls[0];
    expect((defaultCall.body as { locationBias: { circle: { radius: number } } }).locationBias.circle.radius).toBe(1500);

    stub.restore();
    stub = stubFetch([
      { match: "places:autocomplete", json: loadGoogleFixture("autocomplete-empty.json") },
    ]);
    await places.request(
      `/?lat=${SAN_FRANCISCO.lat}&lng=${SAN_FRANCISCO.lng}&q=cos&radius=5000`,
    );
    const customCall = stub.calls[0];
    expect(
      (customCall.body as { locationBias: { circle: { radius: number } } }).locationBias.circle
        .radius,
    ).toBe(5000);
  });
});

function isRankedBy(rankPreference: string) {
  return (body: unknown) => (body as { rankPreference?: string }).rankPreference === rankPreference;
}

describe("GET /places without q", () => {
  it("calls searchNearby, not autocomplete", async () => {
    stub = stubFetch([
      { match: "places:searchNearby", json: loadGoogleFixture("search-nearby.json") },
    ]);

    const response = await places.request(`/?lat=${SAN_FRANCISCO.lat}&lng=${SAN_FRANCISCO.lng}`);
    expect(response.status).toBe(200);

    const body = (await response.json()) as { results: Array<{ name: string }> };
    expect(body.results.map((result) => result.name)).toContain("Blue Bottle Coffee");
    expect(stub.calls.every((call) => !call.url.includes("autocomplete"))).toBe(true);
  });

  it("searches nearest-first and most-popular and passes accuracy through", async () => {
    stub = stubFetch([
      { match: "places:searchNearby", json: loadGoogleFixture("search-nearby.json") },
    ]);

    await places.request(`/?lat=${SAN_FRANCISCO.lat}&lng=${SAN_FRANCISCO.lng}&accuracy=42`);

    const rankPreferences = stub.calls
      .map((call) => (call.body as { rankPreference: string }).rankPreference)
      .sort();
    expect(rankPreferences).toEqual(["DISTANCE", "POPULARITY"]);
  });

  it("only searches by popularity when the fix is too coarse to rank by distance", async () => {
    stub = stubFetch([
      { match: "places:searchNearby", json: loadGoogleFixture("search-nearby.json") },
    ]);

    await places.request(`/?lat=${SAN_FRANCISCO.lat}&lng=${SAN_FRANCISCO.lng}&accuracy=2500`);

    expect(stub.calls).toHaveLength(1);
    expect((stub.calls[0].body as { rankPreference: string }).rankPreference).toBe("POPULARITY");
  });

  it("includes the viewport so the client can tell large venues from storefronts", async () => {
    stub = stubFetch([
      { match: "places:searchNearby", json: loadGoogleFixture("search-nearby-viewport.json") },
    ]);

    const response = await places.request(`/?lat=${SAN_FRANCISCO.lat}&lng=${SAN_FRANCISCO.lng}`);
    const body = (await response.json()) as { results: Array<Record<string, unknown>> };

    expect(body.results[0].viewport).toEqual({
      low: { latitude: 37.7644, longitude: -122.5107 },
      high: { latitude: 37.7745, longitude: -122.4544 },
    });
    expect(body.results[1].viewport).toBeNull();
  });

  it("400s on a negative accuracy", async () => {
    stub = stubFetch([]);

    const response = await places.request(
      `/?lat=${SAN_FRANCISCO.lat}&lng=${SAN_FRANCISCO.lng}&accuracy=-1`,
    );
    expect(response.status).toBe(400);
    expect(stub.calls).toHaveLength(0);
  });

  it("502s only when both nearby searches fail", async () => {
    vi.spyOn(console, "error").mockImplementation(() => {});
    stub = stubFetch([
      { match: "places:searchNearby", matchBody: isRankedBy("DISTANCE"), status: 500, text: "boom" },
      { match: "places:searchNearby", matchBody: isRankedBy("POPULARITY"), json: loadGoogleFixture("search-nearby.json") },
    ]);

    const survivor = await places.request(`/?lat=${SAN_FRANCISCO.lat}&lng=${SAN_FRANCISCO.lng}`);
    expect(survivor.status).toBe(200);

    stub.restore();
    stub = stubFetch([{ match: "places:searchNearby", status: 500, text: "boom" }]);

    const outage = await places.request(`/?lat=${SAN_FRANCISCO.lat}&lng=${SAN_FRANCISCO.lng}`);
    expect(outage.status).toBe(502);
  });
});

describe("GET /places ranking scenarios", () => {
  // Golden tests: each fixture in fixtures/ranking/ stores the raw Google
  // responses for both nearby searches together with the exact `/places`
  // output the recorder derived from them. The iOS ranking tests consume the
  // same `places` array, so this is what keeps the two sides in agreement.
  const fixtureNames = listRankingFixtureNames();

  it("has recorded scenarios to replay", () => {
    expect(fixtureNames.length).toBeGreaterThan(0);
  });

  for (const fixtureName of fixtureNames) {
    it(`replays ${fixtureName} into the recorded places`, async () => {
      const fixture = loadRankingFixture(fixtureName);
      const routes = [
        {
          match: "places:searchNearby",
          matchBody: isRankedBy("POPULARITY"),
          json: fixture.google.popularity.response,
        },
      ];
      if (fixture.google.distance) {
        routes.push({
          match: "places:searchNearby",
          matchBody: isRankedBy("DISTANCE"),
          json: fixture.google.distance.response,
        });
      }
      stub = stubFetch(routes);

      const response = await places.request(
        `/?lat=${fixture.fix.latitude}&lng=${fixture.fix.longitude}&accuracy=${fixture.fix.horizontalAccuracy}`,
      );
      expect(response.status).toBe(200);

      const body = (await response.json()) as { results: unknown[] };
      expect(body.results).toEqual(fixture.places);

      const requestBodies = stub.calls.map((call) => call.body);
      expect(requestBodies).toContainEqual(fixture.google.popularity.request);
      if (fixture.google.distance) {
        expect(requestBodies).toContainEqual(fixture.google.distance.request);
      }
    });
  }
});

describe("GET /places validation", () => {
  it("400s when lat/lng are missing", async () => {
    stub = stubFetch([]);

    const response = await places.request("/?q=cos");
    expect(response.status).toBe(400);

    const body = (await response.json()) as { error: string; details: { fieldErrors: Record<string, unknown> } };
    expect(body.error).toBe("Invalid query parameters");
    expect(body.details.fieldErrors.lat).toBeDefined();
    expect(stub.calls).toHaveLength(0);
  });

  it("400s on an out-of-range latitude", async () => {
    stub = stubFetch([]);

    const response = await places.request("/?lat=200&lng=-122.4194");
    expect(response.status).toBe(400);
  });

  it("400s when radius exceeds the max", async () => {
    stub = stubFetch([]);

    const response = await places.request(
      `/?lat=${SAN_FRANCISCO.lat}&lng=${SAN_FRANCISCO.lng}&radius=60000`,
    );
    expect(response.status).toBe(400);
  });
});

describe("GET /places upstream failures", () => {
  it("502s when autocomplete fails", async () => {
    vi.spyOn(console, "error").mockImplementation(() => {});
    stub = stubFetch([
      { match: "places:autocomplete", status: 500, text: "upstream boom" },
    ]);

    const response = await places.request(
      `/?lat=${SAN_FRANCISCO.lat}&lng=${SAN_FRANCISCO.lng}&q=cos`,
    );
    expect(response.status).toBe(502);
    expect(await response.json()).toEqual({ error: "Failed to fetch places from Google" });
  });

  it("502s when every place detail lookup fails", async () => {
    vi.spyOn(console, "error").mockImplementation(() => {});
    stub = stubFetch([
      { match: "places:autocomplete", json: loadGoogleFixture("autocomplete-cos.json") },
      { match: "/places/ChIJcos", status: 500, text: "detail boom" },
    ]);

    const response = await places.request(
      `/?lat=${SAN_FRANCISCO.lat}&lng=${SAN_FRANCISCO.lng}&q=cos`,
    );
    expect(response.status).toBe(502);
  });

  it("502s when the API key is missing", async () => {
    vi.stubEnv("GOOGLE_PLACES_API_KEY", "");
    stub = stubFetch([]);

    const response = await places.request(
      `/?lat=${SAN_FRANCISCO.lat}&lng=${SAN_FRANCISCO.lng}&q=cos`,
    );
    expect(response.status).toBe(502);
  });

  it("returns an empty result list, not an error, when nothing matches", async () => {
    stub = stubFetch([
      { match: "places:autocomplete", json: loadGoogleFixture("autocomplete-empty.json") },
    ]);

    const response = await places.request(
      `/?lat=${SAN_FRANCISCO.lat}&lng=${SAN_FRANCISCO.lng}&q=zzzznotaplace`,
    );
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ results: [] });
  });

  it("returns an empty result list when autocomplete only returns query predictions", async () => {
    stub = stubFetch([
      {
        match: "places:autocomplete",
        json: loadGoogleFixture("autocomplete-query-predictions-only.json"),
      },
    ]);

    const response = await places.request(
      `/?lat=${SAN_FRANCISCO.lat}&lng=${SAN_FRANCISCO.lng}&q=cos`,
    );
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ results: [] });
    expect(stub.calls).toHaveLength(1);
  });
});

describe("mounted under /places", () => {
  it("responds through the same mount pattern app.ts uses", async () => {
    stub = stubFetch([
      { match: "places:autocomplete", json: loadGoogleFixture("autocomplete-cos.json") },
      { match: "/places/ChIJcos00000COSTCO", json: loadGoogleFixture("details-costco.json") },
      { match: "/places/ChIJcos00001COSBAR", json: loadGoogleFixture("details-cos-bar.json") },
      {
        match: "/places/ChIJcos00002COSCLOTHING",
        json: loadGoogleFixture("details-cos-clothing.json"),
      },
    ]);

    const app = new Hono().route("/places", places);
    const response = await app.request(
      `/places?lat=${SAN_FRANCISCO.lat}&lng=${SAN_FRANCISCO.lng}&q=cos`,
    );
    expect(response.status).toBe(200);
  });
});
