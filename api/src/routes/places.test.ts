import { Hono } from "hono";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { createDatabaseStub } from "../../test/helpers/stub-database.js";
import { listRankingFixtureNames, loadRankingFixture } from "../../test/helpers/fixtures.js";
import { createAccessToken } from "../lib/tokens.js";
import type { CoverageReport } from "../lib/coverage.js";
import type { PlaceResult } from "../lib/place-result.js";

const { database, controls } = createDatabaseStub();

vi.mock("../db/index.js", () => ({ database }));

// Coverage has its own tests; here it is a canned report so the route tests
// script only the place queries.
const describeCoverage = vi.fn(async (): Promise<CoverageReport> => ({ status: "ready" }));
vi.mock("../lib/coverage.js", () => ({ describeCoverage }));

const { places } = await import("./places.js");

const SAN_FRANCISCO = { lat: "37.7749", lng: "-122.4194" };
const CURRENT_USER_ID = "550e8400-e29b-41d4-a716-446655440000";
const SESSION_ID = "22222222-2222-2222-2222-222222222222";
const accessToken = await createAccessToken(CURRENT_USER_ID, SESSION_ID);

beforeEach(() => {
  controls.reset();
  describeCoverage.mockClear();
  describeCoverage.mockResolvedValue({ status: "ready" });
});

function placeRow(overrides: Record<string, unknown> = {}) {
  return {
    id: "a2c1f0e4-6b7d-4e3a-9c1f-1d2e3f4a5b6c",
    source: "overture",
    overtureId: "08f2830828d3a8db0344a5b5c2fd1a3e",
    googlePlaceId: null,
    name: "Costco Wholesale",
    primaryType: "wholesale_store",
    types: ["wholesale_store", "grocery_store"],
    addressStreet: "450 10th St",
    addressLocality: "San Francisco",
    addressRegion: "US-CA",
    addressPostcode: "94103",
    addressCountry: "US",
    latitude: 37.7706,
    longitude: -122.4108,
    confidence: 0.93,
    website: null,
    phone: null,
    createdByUserId: null,
    extentOvertureId: null,
    extentAreaSquareMeters: null,
    isPrivate: false,
    lastSeenRelease: "2026-09-23.0",
    retiredAt: null,
    extentGeoJson: null,
    extentSouth: null,
    extentWest: null,
    extentNorth: null,
    extentEast: null,
    distanceMeters: null,
    createdAt: new Date("2026-09-01T00:00:00.000Z"),
    updatedAt: new Date("2026-09-01T00:00:00.000Z"),
    checkinCount: 2,
    ...overrides,
  };
}

/** The `places` row a recorded `/places` result must have come from. */
function rowFromResult(result: PlaceResult) {
  return placeRow({
    id: result.id,
    source: result.source,
    overtureId: result.source === "overture" ? `overture-${result.id}` : null,
    googlePlaceId: result.source === "google" ? result.id : null,
    name: result.name,
    primaryType: result.primaryType,
    types: result.types,
    addressStreet: result.street,
    addressLocality: result.locality,
    addressRegion: result.region,
    addressPostcode: result.postcode,
    addressCountry: result.country,
    latitude: result.location?.latitude ?? null,
    longitude: result.location?.longitude ?? null,
    website: result.website,
    phone: result.phone,
    checkinCount: result.checkinCount,
    isPrivate: result.isPrivate,
    retiredAt: result.retired ? new Date("2026-09-01T00:00:00.000Z") : null,
    distanceMeters: result.distanceMeters,
    // The recorded rings are each polygon's outer ring; the row holds the
    // MultiPolygon the search selected them from.
    extentGeoJson: result.extent
      ? JSON.stringify({ type: "MultiPolygon", coordinates: result.extent.rings.map((ring) => [ring]) })
      : null,
    extentAreaSquareMeters: result.extent?.areaSquareMeters ?? null,
    extentSouth: result.extent?.boundingBox.south ?? null,
    extentWest: result.extent?.boundingBox.west ?? null,
    extentNorth: result.extent?.boundingBox.north ?? null,
    extentEast: result.extent?.boundingBox.east ?? null,
  });
}

function post(body: unknown, authenticated = true) {
  return places.request("/", {
    method: "POST",
    headers: {
      ...(authenticated ? { Authorization: `Bearer ${accessToken}` } : {}),
      "Content-Type": "application/json",
    },
    body: JSON.stringify(body),
  });
}

describe("GET /places?q=", () => {
  it("runs a single name search and returns the rows in the database's order", async () => {
    controls.queue([placeRow(), placeRow({ id: "b2c1f0e4-6b7d-4e3a-9c1f-1d2e3f4a5b6c", name: "Cos Bar" })]);

    const response = await places.request(
      `/?lat=${SAN_FRANCISCO.lat}&lng=${SAN_FRANCISCO.lng}&q=cos`,
    );
    expect(response.status).toBe(200);

    const body = (await response.json()) as { results: Array<{ name: string }> };
    expect(body.results.map((result) => result.name)).toEqual(["Costco Wholesale", "Cos Bar"]);
    expect(controls.operations).toEqual(["select"]);
  });

  it("returns the result shape the iOS client decodes", async () => {
    controls.queue([placeRow()]);

    const response = await places.request(
      `/?lat=${SAN_FRANCISCO.lat}&lng=${SAN_FRANCISCO.lng}&q=costco`,
    );
    const body = (await response.json()) as { results: unknown[] };

    expect(body.results[0]).toEqual({
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
      checkinCount: 2,
      isPrivate: false,
      retired: false,
      website: null,
      phone: null,
    });
  });

  it("returns the extent and the distance the search computed", async () => {
    controls.queue([
      placeRow({
        name: "Golden Gate Park",
        primaryType: "park",
        types: ["park"],
        extentGeoJson: JSON.stringify({ type: "MultiPolygon", coordinates: [[[[-122.51, 37.76], [-122.45, 37.76], [-122.45, 37.77], [-122.51, 37.77], [-122.51, 37.76]]]] }),
        extentSouth: 37.76,
        extentWest: -122.51,
        extentNorth: 37.77,
        extentEast: -122.45,
        extentAreaSquareMeters: 4_100_000,
        distanceMeters: 0,
      }),
    ]);

    const response = await places.request(`/?lat=37.7694&lng=-122.4862&q=golden`);
    const body = (await response.json()) as { results: Array<Record<string, unknown>> };

    expect(body.results[0].distanceMeters).toBe(0);
    expect(body.results[0].extent).toEqual({
      boundingBox: { south: 37.76, west: -122.51, north: 37.77, east: -122.45 },
      rings: [[[-122.51, 37.76], [-122.45, 37.76], [-122.45, 37.77], [-122.51, 37.77], [-122.51, 37.76]]],
      areaSquareMeters: 4_100_000,
    });
  });

  it("includes the coverage report alongside the results", async () => {
    controls.queue([]);
    describeCoverage.mockResolvedValue({ status: "importing", estimatedSecondsRemaining: 90 });

    const response = await places.request(`/?lat=${SAN_FRANCISCO.lat}&lng=${SAN_FRANCISCO.lng}&q=cos`);
    const body = (await response.json()) as { coverage: unknown };

    expect(body.coverage).toEqual({ status: "importing", estimatedSecondsRemaining: 90 });
    expect(describeCoverage).toHaveBeenCalledWith({ latitude: 37.7749, longitude: -122.4194, viewerUserId: null, passive: false });
  });

  it("marks a passive lookup so coverage is reported but never fetched", async () => {
    controls.queue([]);
    const response = await places.request(`/?lat=${SAN_FRANCISCO.lat}&lng=${SAN_FRANCISCO.lng}&passive=1`, {
      headers: { Authorization: `Bearer ${accessToken}` },
    });
    expect(response.status).toBe(200);
    expect(describeCoverage).toHaveBeenCalledWith(expect.objectContaining({ viewerUserId: CURRENT_USER_ID, passive: true }));
  });

  it("passes the signed-in viewer to the search and to coverage", async () => {
    controls.queue([]);
    const response = await places.request(`/?lat=${SAN_FRANCISCO.lat}&lng=${SAN_FRANCISCO.lng}&q=cos`, {
      headers: { Authorization: `Bearer ${accessToken}` },
    });
    expect(response.status).toBe(200);
    expect(describeCoverage).toHaveBeenCalledWith(expect.objectContaining({ viewerUserId: CURRENT_USER_ID }));
  });

  it("401s on a bad token instead of treating the caller as anonymous", async () => {
    const response = await places.request(`/?lat=${SAN_FRANCISCO.lat}&lng=${SAN_FRANCISCO.lng}&q=cos`, {
      headers: { Authorization: "Bearer not-a-token" },
    });
    expect(response.status).toBe(401);
    expect(controls.operations).toEqual([]);
  });

  it("maps missing optional fields to null", async () => {
    controls.queue([
      placeRow({
        source: "user",
        overtureId: null,
        createdByUserId: CURRENT_USER_ID,
        primaryType: null,
        types: [],
        addressStreet: null,
        addressLocality: null,
        addressRegion: null,
        addressPostcode: null,
        addressCountry: null,
        checkinCount: 0,
      }),
    ]);

    const response = await places.request(
      `/?lat=${SAN_FRANCISCO.lat}&lng=${SAN_FRANCISCO.lng}&q=cos`,
    );
    const body = (await response.json()) as { results: Array<Record<string, unknown>> };

    expect(body.results[0]).toMatchObject({
      source: "user",
      address: null,
      street: null,
      locality: null,
      types: [],
      primaryType: null,
      checkinCount: 0,
    });
  });

  it("returns an empty result list, not an error, when nothing matches", async () => {
    controls.queue([]);

    const response = await places.request(
      `/?lat=${SAN_FRANCISCO.lat}&lng=${SAN_FRANCISCO.lng}&q=zzzznotaplace`,
    );
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ results: [], coverage: { status: "ready" } });
  });
});

describe("GET /places without q", () => {
  it("searches nearest pins, then grounds, then large venues, in that order in the output", async () => {
    controls.queue(
      [placeRow({ id: "11111111-1111-4111-8111-111111111111", name: "Blue Bottle Coffee" })],
      [placeRow({ id: "33333333-3333-4333-8333-333333333333", name: "SFO", types: ["airport"] })],
      [placeRow({ id: "22222222-2222-4222-8222-222222222222", name: "Golden Gate Park", types: ["park"] })],
    );

    const response = await places.request(
      `/?lat=${SAN_FRANCISCO.lat}&lng=${SAN_FRANCISCO.lng}&accuracy=42`,
    );
    expect(response.status).toBe(200);

    const body = (await response.json()) as { results: Array<{ name: string }> };
    expect(body.results.map((result) => result.name)).toEqual([
      "Blue Bottle Coffee",
      "SFO",
      "Golden Gate Park",
    ]);
    expect(controls.operations).toEqual(["select", "select", "select"]);
  });

  it("lists a large venue once when several searches return it", async () => {
    const park = placeRow({ id: "22222222-2222-4222-8222-222222222222", name: "Golden Gate Park", types: ["park"] });
    controls.queue([placeRow(), park], [park], [park]);

    const response = await places.request(`/?lat=${SAN_FRANCISCO.lat}&lng=${SAN_FRANCISCO.lng}`);
    const body = (await response.json()) as { results: Array<{ name: string }> };

    expect(body.results.map((result) => result.name)).toEqual(["Costco Wholesale", "Golden Gate Park"]);
  });

  it("skips the nearest-pin search when the fix is too coarse to rank by distance", async () => {
    controls.queue([], [placeRow({ name: "Golden Gate Park", types: ["park"] })]);

    const response = await places.request(
      `/?lat=${SAN_FRANCISCO.lat}&lng=${SAN_FRANCISCO.lng}&accuracy=2500`,
    );
    expect(response.status).toBe(200);
    expect(controls.operations).toEqual(["select", "select"]);
  });

  it("400s on a negative accuracy", async () => {
    const response = await places.request(
      `/?lat=${SAN_FRANCISCO.lat}&lng=${SAN_FRANCISCO.lng}&accuracy=-1`,
    );
    expect(response.status).toBe(400);
    expect(controls.operations).toEqual([]);
  });

  it("500s when the database fails", async () => {
    vi.spyOn(console, "error").mockImplementation(() => {});
    controls.queueFailure(new Error("connection reset"));
    controls.queueFailure(new Error("connection reset"));
    controls.queueFailure(new Error("connection reset"));

    const response = await places.request(`/?lat=${SAN_FRANCISCO.lat}&lng=${SAN_FRANCISCO.lng}`);
    expect(response.status).toBe(500);
    expect(await response.json()).toEqual({ error: "Failed to search places" });
  });
});

describe("GET /places ranking scenarios", () => {
  // Golden tests: each fixture in fixtures/ranking/ stores the exact `/places`
  // output the recorder captured for its fix. The iOS ranking tests consume
  // the same `places` array, so this is what keeps the two sides in
  // agreement: every recorded result must round-trip through the row shape
  // the database returns and the result mapping the route applies.
  const fixtureNames = listRankingFixtureNames();

  it("has recorded scenarios to replay", () => {
    expect(fixtureNames.length).toBeGreaterThan(0);
  });

  for (const fixtureName of fixtureNames) {
    it(`replays ${fixtureName} into the recorded places`, async () => {
      const fixture = loadRankingFixture(fixtureName);
      expect(fixture.schemaVersion).toBe(3);

      const rows = fixture.places.map(rowFromResult);
      const searchesByDistance = fixture.fix.horizontalAccuracy <= 1000;
      if (searchesByDistance) {
        controls.queue(rows, [], []);
      } else {
        controls.queue(rows, []);
      }

      const response = await places.request(
        `/?lat=${fixture.fix.latitude}&lng=${fixture.fix.longitude}&accuracy=${fixture.fix.horizontalAccuracy}`,
      );
      expect(response.status).toBe(200);

      const body = (await response.json()) as { results: unknown[] };
      expect(body.results).toEqual(fixture.places);
      expect(controls.operations).toHaveLength(searchesByDistance ? 3 : 2);
    });
  }
});

describe("GET /places validation", () => {
  it("400s when lat/lng are missing", async () => {
    const response = await places.request("/?q=cos");
    expect(response.status).toBe(400);

    const body = (await response.json()) as { error: string; details: { fieldErrors: Record<string, unknown> } };
    expect(body.error).toBe("Invalid query parameters");
    expect(body.details.fieldErrors.lat).toBeDefined();
    expect(controls.operations).toEqual([]);
  });

  it("400s on an out-of-range latitude", async () => {
    const response = await places.request("/?lat=200&lng=-122.4194");
    expect(response.status).toBe(400);
  });

  it("400s when radius exceeds the max", async () => {
    const response = await places.request(
      `/?lat=${SAN_FRANCISCO.lat}&lng=${SAN_FRANCISCO.lng}&radius=60000`,
    );
    expect(response.status).toBe(400);
  });
});

describe("GET /places/:id", () => {
  it("returns the place", async () => {
    controls.queue([placeRow()]);

    const response = await places.request("/a2c1f0e4-6b7d-4e3a-9c1f-1d2e3f4a5b6c");
    expect(response.status).toBe(200);
    expect((await response.json()) as { name: string }).toMatchObject({ name: "Costco Wholesale" });
  });

  it("404s for an unknown id and 400s for a malformed one", async () => {
    controls.queue([]);
    expect((await places.request("/a2c1f0e4-6b7d-4e3a-9c1f-1d2e3f4a5b6d")).status).toBe(404);
    expect((await places.request("/not-a-uuid")).status).toBe(400);
  });
});

describe("POST /places", () => {
  const venue = {
    name: "Sam's Garage Bar",
    primaryType: "bar",
    types: ["cocktail_bar", "bar"],
    street: "12 Elm St",
    locality: "Truckee",
    region: "US-CA",
    postcode: "96161",
    country: "us",
    latitude: 39.3279,
    longitude: -120.1833,
    website: "https://example.com",
    phone: "+1 530-555-0100",
  };

  it("creates a user venue for the signed-in user, private by default", async () => {
    controls.queue([
      placeRow({
        id: "c3c1f0e4-6b7d-4e3a-9c1f-1d2e3f4a5b6c",
        source: "user",
        overtureId: null,
        name: venue.name,
        primaryType: "bar",
        types: ["bar", "cocktail_bar"],
        addressStreet: venue.street,
        addressLocality: venue.locality,
        addressRegion: venue.region,
        addressPostcode: venue.postcode,
        addressCountry: "US",
        latitude: venue.latitude,
        longitude: venue.longitude,
        website: venue.website,
        phone: venue.phone,
        isPrivate: true,
        createdByUserId: CURRENT_USER_ID,
      }),
    ]);

    const response = await post(venue);
    expect(response.status).toBe(201);

    const body = (await response.json()) as Record<string, unknown>;
    expect(body).toMatchObject({
      source: "user",
      name: "Sam's Garage Bar",
      address: "12 Elm St, Truckee, CA 96161, US",
      primaryType: "bar",
      types: ["bar", "cocktail_bar"],
      location: { latitude: 39.3279, longitude: -120.1833 },
      checkinCount: 0,
      isPrivate: true,
      retired: false,
    });
    expect(controls.operations).toEqual(["insert"]);
  });

  it("400s on a non-boolean isPrivate", async () => {
    const response = await post({ ...venue, isPrivate: "yes" });
    expect(response.status).toBe(400);
  });

  it("401s without a token", async () => {
    const response = await post(venue, false);
    expect(response.status).toBe(401);
    expect(controls.operations).toEqual([]);
  });

  it("400s without a pin", async () => {
    const { latitude: _latitude, ...withoutPin } = venue;
    const response = await post(withoutPin);
    expect(response.status).toBe(400);

    const body = (await response.json()) as { details: { fieldErrors: Record<string, unknown> } };
    expect(body.details.fieldErrors.latitude).toBeDefined();
    expect(controls.operations).toEqual([]);
  });

  it("400s on a category that is not a code", async () => {
    const response = await post({ ...venue, primaryType: "Coffee Shop" });
    expect(response.status).toBe(400);
  });

  it("400s on a country that is not a two-letter code", async () => {
    const response = await post({ ...venue, country: "USA" });
    expect(response.status).toBe(400);
  });

  it("400s on a malformed body", async () => {
    const response = await places.request("/", {
      method: "POST",
      headers: { Authorization: `Bearer ${accessToken}`, "Content-Type": "application/json" },
      body: "{not json",
    });
    expect(response.status).toBe(400);
  });
});

describe("mounted under /places", () => {
  it("responds through the same mount pattern app.ts uses", async () => {
    controls.queue([placeRow()]);

    const app = new Hono().route("/places", places);
    const response = await app.request(
      `/places?lat=${SAN_FRANCISCO.lat}&lng=${SAN_FRANCISCO.lng}&q=cos`,
    );
    expect(response.status).toBe(200);
  });
});
