import { PgDialect } from "drizzle-orm/pg-core";
import type { SQL } from "drizzle-orm";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { createDatabaseStub } from "../../test/helpers/stub-database.js";
import { createAccessToken } from "../lib/tokens.js";

const { database, controls } = createDatabaseStub();

vi.mock("../db/index.js", () => ({ database }));

const { checkins } = await import("./checkins.js");
const { isVisibleCheckin } = await import("../lib/friendships.js");

const CURRENT_USER_ID = "550e8400-e29b-41d4-a716-446655440000";
const SESSION_ID = "22222222-2222-2222-2222-222222222222";

const accessToken = await createAccessToken(CURRENT_USER_ID, SESSION_ID);

const dialect = new PgDialect();

const SAVED_ROW = {
  id: "0f1c5a8e-4c6c-4a3b-9c48-2f4d1a0a3d11",
  userId: CURRENT_USER_ID,
  googlePlaceId: "ChIJpreview",
  placeName: "Blue Bottle Coffee",
  placeAddress: "315 Linden St, San Francisco",
  placePrimaryType: "cafe",
  placeTypes: ["cafe", "coffee_shop"],
  latitude: 37.7764,
  longitude: -122.4231,
  message: null,
  visibility: "private",
  source: "visit",
  createdAt: new Date("2026-09-20T14:15:00.000Z"),
  updatedAt: new Date("2026-09-21T10:00:00.000Z"),
};

const VALID_BODY = {
  googlePlaceId: "ChIJpreview",
  placeName: "Blue Bottle Coffee",
};

function send(method: string, path: string, body?: unknown) {
  return checkins.request(path, {
    method,
    headers: {
      Authorization: `Bearer ${accessToken}`,
      "Content-Type": "application/json",
    },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
}

/** The arguments of every chained call named `method`, in order. */
function argumentsOf(method: string) {
  return controls.chainedCalls
    .filter((call) => call.method === method)
    .map((call) => call.arguments[0]);
}

beforeEach(() => {
  controls.reset();
});

describe("POST /checkins visibility and source", () => {
  it("defaults to a public, manual checkin", async () => {
    controls.queue([SAVED_ROW]);
    const response = await send("POST", "/", VALID_BODY);
    expect(response.status).toBe(201);

    const [inserted] = argumentsOf("values");
    expect(inserted).toMatchObject({ visibility: "public", source: "manual" });
    expect(inserted).not.toHaveProperty("createdAt");
  });

  it("stores a private checkin accepted from a visit with its arrival time", async () => {
    controls.queue([SAVED_ROW]);
    const response = await send("POST", "/", {
      ...VALID_BODY,
      visibility: "private",
      source: "visit",
      createdAt: "2026-09-20T14:15:00.000Z",
    });
    expect(response.status).toBe(201);

    expect(argumentsOf("values")[0]).toMatchObject({
      userId: CURRENT_USER_ID,
      visibility: "private",
      source: "visit",
      createdAt: new Date("2026-09-20T14:15:00.000Z"),
    });
  });

  it("returns visibility and source in the same shape the iOS client decodes", async () => {
    controls.queue([SAVED_ROW]);
    const response = await send("POST", "/", { ...VALID_BODY, visibility: "private", source: "visit" });
    const body = (await response.json()) as Record<string, unknown>;

    expect(body).toEqual({
      id: SAVED_ROW.id,
      userId: CURRENT_USER_ID,
      googlePlaceId: "ChIJpreview",
      placeName: "Blue Bottle Coffee",
      placeAddress: "315 Linden St, San Francisco",
      placePrimaryType: "cafe",
      placeTypes: ["cafe", "coffee_shop"],
      location: { latitude: 37.7764, longitude: -122.4231 },
      message: null,
      visibility: "private",
      source: "visit",
      createdAt: "2026-09-20T14:15:00.000Z",
      updatedAt: "2026-09-21T10:00:00.000Z",
    });
  });

  it("400s on an unknown visibility", async () => {
    const response = await send("POST", "/", { ...VALID_BODY, visibility: "friends" });
    expect(response.status).toBe(400);

    const body = (await response.json()) as { details: { fieldErrors: Record<string, unknown> } };
    expect(body.details.fieldErrors.visibility).toBeDefined();
    expect(controls.operations).toEqual([]);
  });

  it("400s on an unknown source", async () => {
    const response = await send("POST", "/", { ...VALID_BODY, source: "import" });
    expect(response.status).toBe(400);
  });

  it("400s when createdAt is in the future", async () => {
    const nextWeek = new Date(Date.now() + 7 * 24 * 60 * 60 * 1000).toISOString();
    const response = await send("POST", "/", { ...VALID_BODY, createdAt: nextWeek });
    expect(response.status).toBe(400);

    const body = (await response.json()) as { details: { fieldErrors: Record<string, unknown> } };
    expect(body.details.fieldErrors.createdAt).toBeDefined();
  });

  it("400s when createdAt is not an ISO 8601 timestamp", async () => {
    const response = await send("POST", "/", { ...VALID_BODY, createdAt: "yesterday" });
    expect(response.status).toBe(400);
  });

  it("accepts a createdAt a minute ahead of the server clock", async () => {
    controls.queue([SAVED_ROW]);
    const shortlyAhead = new Date(Date.now() + 60 * 1000).toISOString();
    const response = await send("POST", "/", { ...VALID_BODY, createdAt: shortlyAhead });
    expect(response.status).toBe(201);
  });
});

describe("isVisibleCheckin", () => {
  it("shows all of your own checkins but only your friends' public ones", () => {
    const query = dialect.sqlToQuery(isVisibleCheckin(CURRENT_USER_ID));

    // Your own: `user_id = $1` with no visibility check alongside it.
    expect(query.sql).toMatch(/^\("checkins"\."user_id" = \$1 or \(/);
    // A friend's: the friend subquery and the public check, joined by `and`.
    expect(query.sql).toMatch(/"checkins"\."user_id" in \(.*\) and "checkins"\."visibility" = \$\d+\)\)$/s);
    expect(query.params).toContain("public");
  });

  it("is the condition GET /checkins filters by", async () => {
    controls.queue([]);
    const response = await send("GET", "/");
    expect(response.status).toBe(200);

    const listed = dialect.sqlToQuery(argumentsOf("where")[0] as SQL);
    const visible = dialect.sqlToQuery(isVisibleCheckin(CURRENT_USER_ID));
    expect(listed.sql).toContain(visible.sql);
  });
});

describe("PATCH /checkins/:id visibility", () => {
  it("updates visibility", async () => {
    controls.queue([{ ...SAVED_ROW, visibility: "public" }]);
    const response = await send("PATCH", `/${SAVED_ROW.id}`, { visibility: "public" });
    expect(response.status).toBe(200);
    expect(argumentsOf("set")).toEqual([{ visibility: "public" }]);
  });

  it("still rejects an empty update", async () => {
    const response = await send("PATCH", `/${SAVED_ROW.id}`, {});
    expect(response.status).toBe(400);
    expect(controls.operations).toEqual([]);
  });
});
