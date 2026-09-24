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
const PLACE_ID = "a2c1f0e4-6b7d-4e3a-9c1f-1d2e3f4a5b6c";
const CHECKIN_ID = "880e8400-e29b-41d4-a716-446655440000";

const VALID_BODY = { placeId: PLACE_ID };

const accessToken = await createAccessToken(CURRENT_USER_ID, SESSION_ID);

const dialect = new PgDialect();

beforeEach(() => {
  controls.reset();
});

function placeRow() {
  return {
    id: PLACE_ID,
    source: "overture",
    overtureId: "08f2830828d3a8db0344a5b5c2fd1a3e",
    googlePlaceId: null,
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
    confidence: 0.95,
    website: null,
    phone: null,
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
    checkinCount: 4,
  };
}

function checkinRow(overrides: Record<string, unknown> = {}) {
  return {
    id: CHECKIN_ID,
    userId: CURRENT_USER_ID,
    placeId: PLACE_ID,
    placeName: "Blue Bottle Coffee",
    placeAddress: "66 Mint St, San Francisco, CA 94103, US",
    placeLocality: "San Francisco",
    placePrimaryType: "coffee_shop",
    placeTypes: ["coffee_shop", "cafe"],
    latitude: 37.7823,
    longitude: -122.4076,
    message: "Cortado o'clock",
    visibility: "friends",
    source: "manual",
    createdAt: new Date("2026-09-20T15:00:00.000Z"),
    updatedAt: new Date("2026-09-20T15:00:00.000Z"),
    ...overrides,
  };
}

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

describe("POST /checkins", () => {
  it("snapshots the place from the database, not from the client", async () => {
    controls.queue([placeRow()], [checkinRow()]);

    const response = await send("POST", "/", {
      placeId: PLACE_ID,
      message: "Cortado o'clock",
      // An older client's snapshot fields are ignored, never trusted.
      placeName: "Somewhere Else",
    });
    expect(response.status).toBe(201);
    expect(controls.operations).toEqual(["select", "insert"]);

    const body = (await response.json()) as Record<string, unknown>;
    expect(body).toMatchObject({
      id: CHECKIN_ID,
      userId: CURRENT_USER_ID,
      placeId: PLACE_ID,
      placeName: "Blue Bottle Coffee",
      placeAddress: "66 Mint St, San Francisco, CA 94103, US",
      placeLocality: "San Francisco",
      placePrimaryType: "coffee_shop",
      location: { latitude: 37.7823, longitude: -122.4076 },
      message: "Cortado o'clock",
    });
    expect(body).not.toHaveProperty("googlePlaceId");
  });

  it("404s at a place a newer Overture release dropped", async () => {
    controls.queue([{ ...placeRow(), retiredAt: new Date("2026-09-20T00:00:00.000Z") }]);

    const response = await send("POST", "/", { placeId: PLACE_ID });
    expect(response.status).toBe(404);
    expect(controls.operations).toEqual(["select"]);
  });

  it("404s when the place does not exist, before inserting anything", async () => {
    controls.queue([]);

    const response = await send("POST", "/", { placeId: PLACE_ID });
    expect(response.status).toBe(404);
    expect(await response.json()).toEqual({ error: "Place not found" });
    expect(controls.operations).toEqual(["select"]);
  });

  it("400s without a placeId", async () => {
    const response = await send("POST", "/", { message: "hello" });
    expect(response.status).toBe(400);

    const body = (await response.json()) as { details: { fieldErrors: Record<string, unknown> } };
    expect(body.details.fieldErrors.placeId).toBeDefined();
    expect(controls.operations).toEqual([]);
  });

  it("400s on a placeId that is not a uuid, such as an old Google id", async () => {
    const response = await send("POST", "/", { placeId: "ChIJIQBpAG2ahYAR_6128GcTUEo" });
    expect(response.status).toBe(400);
    expect(controls.operations).toEqual([]);
  });

  it("401s without a token", async () => {
    const response = await checkins.request("/", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ placeId: PLACE_ID }),
    });
    expect(response.status).toBe(401);
  });
});

describe("GET /checkins", () => {
  it("filters by placeId", async () => {
    // The list selects each checkin alongside its like and comment counts.
    controls.queue([{ checkin: checkinRow(), likeCount: 0, commentCount: 0, likedByMe: false }]);

    const response = await send("GET", `/?placeId=${PLACE_ID}`);
    expect(response.status).toBe(200);

    const body = (await response.json()) as { results: Array<{ placeId: string }> };
    expect(body.results[0].placeId).toBe(PLACE_ID);
  });

  it("400s on a placeId that is not a uuid", async () => {
    const response = await send("GET", "/?placeId=ChIJIQBpAG2ahYAR_6128GcTUEo");
    expect(response.status).toBe(400);
    expect(controls.operations).toEqual([]);
  });
});

/** The arguments of every chained call named `method`, in order. */
function argumentsOf(method: string) {
  return controls.chainedCalls
    .filter((call) => call.method === method)
    .map((call) => call.arguments[0]);
}

describe("POST /checkins visibility and source", () => {
  it("defaults to a friends-visible, manual checkin", async () => {
    controls.queue([placeRow()], [checkinRow()]);
    const response = await send("POST", "/", VALID_BODY);
    expect(response.status).toBe(201);

    const [inserted] = argumentsOf("values");
    expect(inserted).toMatchObject({ visibility: "friends", source: "manual" });
    expect(inserted).not.toHaveProperty("createdAt");
  });

  it("stores a private checkin accepted from a visit with its arrival time", async () => {
    controls.queue([placeRow()], [checkinRow()]);
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
    controls.queue(
      [placeRow()],
      [
        checkinRow({
          message: null,
          visibility: "private",
          source: "visit",
          createdAt: new Date("2026-09-20T14:15:00.000Z"),
          updatedAt: new Date("2026-09-21T10:00:00.000Z"),
        }),
      ],
    );
    const response = await send("POST", "/", { ...VALID_BODY, visibility: "private", source: "visit" });
    const body = (await response.json()) as Record<string, unknown>;

    expect(body).toEqual({
      id: CHECKIN_ID,
      userId: CURRENT_USER_ID,
      placeId: PLACE_ID,
      placeName: "Blue Bottle Coffee",
      placeAddress: "66 Mint St, San Francisco, CA 94103, US",
      placeLocality: "San Francisco",
      placePrimaryType: "coffee_shop",
      placeTypes: ["coffee_shop", "cafe"],
      location: { latitude: 37.7823, longitude: -122.4076 },
      message: null,
      visibility: "private",
      source: "visit",
      likeCount: 0,
      commentCount: 0,
      likedByMe: false,
      createdAt: "2026-09-20T14:15:00.000Z",
      updatedAt: "2026-09-21T10:00:00.000Z",
    });
  });

  it("400s on an unknown visibility such as \"public\"", async () => {
    const response = await send("POST", "/", { ...VALID_BODY, visibility: "public" });
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
    controls.queue([placeRow()], [checkinRow()]);
    const shortlyAhead = new Date(Date.now() + 60 * 1000).toISOString();
    const response = await send("POST", "/", { ...VALID_BODY, createdAt: shortlyAhead });
    expect(response.status).toBe(201);
  });
});

describe("isVisibleCheckin", () => {
  it("shows all of your own checkins but only your friends' non-private ones", () => {
    const query = dialect.sqlToQuery(isVisibleCheckin(CURRENT_USER_ID));

    // Your own: `user_id = $1` with no visibility check alongside it.
    expect(query.sql).toMatch(/^\("checkins"\."user_id" = \$1 or \(/);
    // A friend's: the friend subquery and the visibility check, joined by `and`.
    expect(query.sql).toMatch(/"checkins"\."user_id" in \(.*\) and "checkins"\."visibility" = \$\d+\)\)$/s);
    expect(query.params).toContain("friends");
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
    controls.queue([checkinRow({ visibility: "friends" })]);
    const response = await send("PATCH", `/${CHECKIN_ID}`, { visibility: "friends" });
    expect(response.status).toBe(200);
    expect(argumentsOf("set")).toEqual([{ visibility: "friends" }]);
  });

  it("still rejects an empty update", async () => {
    const response = await send("PATCH", `/${CHECKIN_ID}`, {});
    expect(response.status).toBe(400);
    expect(controls.operations).toEqual([]);
  });
});

const OTHER_USER_ID = "660e8400-e29b-41d4-a716-446655440000";
const LIKE_ID = "990e8400-e29b-41d4-a716-446655440000";
const COMMENT_ID = "aa0e8400-e29b-41d4-a716-446655440000";

function userRow(overrides: Record<string, unknown> = {}) {
  return {
    id: OTHER_USER_ID,
    email: "friend@example.com",
    emailVerifiedAt: null,
    appleUserId: null,
    appleEmail: null,
    name: "Alex",
    bio: null,
    avatarKey: null,
    isTestUser: false,
    createdAt: new Date("2026-01-01T00:00:00.000Z"),
    updatedAt: new Date("2026-01-01T00:00:00.000Z"),
    ...overrides,
  };
}

function commentRow(overrides: Record<string, unknown> = {}) {
  return {
    id: COMMENT_ID,
    checkinId: CHECKIN_ID,
    userId: CURRENT_USER_ID,
    body: "Great spot",
    createdAt: new Date("2026-09-22T10:00:00.000Z"),
    updatedAt: new Date("2026-09-22T10:00:00.000Z"),
    ...overrides,
  };
}

/** What findVisibleCheckin answers for a friend's checkin. */
const FRIENDS_CHECKIN = { id: CHECKIN_ID, userId: OTHER_USER_ID };
const OWN_CHECKIN = { id: CHECKIN_ID, userId: CURRENT_USER_ID };

describe("GET /checkins pagination", () => {
  it("pages by a createdAt cursor", async () => {
    controls.queue([]);
    const response = await send("GET", "/?before=2026-09-01T00:00:00.000Z&limit=5");
    expect(response.status).toBe(200);

    const listed = dialect.sqlToQuery(argumentsOf("where")[0] as SQL);
    expect(listed.sql).toMatch(/"checkins"\."created_at" < \$\d+/);
    expect(listed.params).toContain("2026-09-01T00:00:00.000Z");
    expect(controls.chainedCalls.map((call) => call.method)).not.toContain("offset");
  });

  it("rejects a before that is not a timestamp", async () => {
    const response = await send("GET", "/?before=last-week");
    expect(response.status).toBe(400);
    expect(controls.operations).toEqual([]);
  });
});

describe("POST /checkins/:id/likes", () => {
  it("likes a friend's checkin and tells them", async () => {
    controls.queue(
      [FRIENDS_CHECKIN],
      [{ id: LIKE_ID }], // the like was new
      [], // the notification insert
      [{ likeCount: 1, commentCount: 0, likedByMe: true }],
    );

    const response = await send("POST", `/${CHECKIN_ID}/likes`);

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ likeCount: 1, likedByMe: true });
    expect(controls.operations).toEqual(["select", "insert", "insert", "select"]);
    expect(argumentsOf("values")[1]).toEqual({
      recipientId: OTHER_USER_ID,
      actorId: CURRENT_USER_ID,
      kind: "like",
      checkinId: CHECKIN_ID,
    });
  });

  it("is a no-op the second time, without a second notification", async () => {
    controls.queue(
      [FRIENDS_CHECKIN],
      [], // the unique index swallowed the insert
      [{ likeCount: 1, commentCount: 0, likedByMe: true }],
    );

    const response = await send("POST", `/${CHECKIN_ID}/likes`);

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ likeCount: 1, likedByMe: true });
    expect(controls.operations).toEqual(["select", "insert", "select"]);
  });

  it("does not notify you about liking your own checkin", async () => {
    controls.queue([OWN_CHECKIN], [{ id: LIKE_ID }], [{ likeCount: 1, commentCount: 0, likedByMe: true }]);

    const response = await send("POST", `/${CHECKIN_ID}/likes`);

    expect(response.status).toBe(200);
    expect(controls.operations).toEqual(["select", "insert", "select"]);
  });

  it("answers 404 for a checkin you cannot see, without writing", async () => {
    controls.queue([]);

    const response = await send("POST", `/${CHECKIN_ID}/likes`);

    expect(response.status).toBe(404);
    expect(controls.operations).toEqual(["select"]);
  });

  it("rejects a malformed checkin id", async () => {
    const response = await send("POST", "/nope/likes");
    expect(response.status).toBe(400);
    expect(controls.operations).toEqual([]);
  });
});

describe("DELETE /checkins/:id/likes", () => {
  it("removes your like and reports the new count", async () => {
    controls.queue([FRIENDS_CHECKIN], [], [{ likeCount: 0, commentCount: 0, likedByMe: false }]);

    const response = await send("DELETE", `/${CHECKIN_ID}/likes`);

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ likeCount: 0, likedByMe: false });
    expect(controls.operations).toEqual(["select", "delete", "select"]);
  });

  it("answers 404 for a checkin you cannot see", async () => {
    controls.queue([]);
    const response = await send("DELETE", `/${CHECKIN_ID}/likes`);
    expect(response.status).toBe(404);
    expect(controls.operations).toEqual(["select"]);
  });
});

describe("GET /checkins/:id/comments", () => {
  it("lists comments with a summary of each author", async () => {
    controls.queue([FRIENDS_CHECKIN], [{ comment: commentRow({ userId: OTHER_USER_ID }), user: userRow() }]);

    const response = await send("GET", `/${CHECKIN_ID}/comments`);

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({
      results: [
        {
          id: COMMENT_ID,
          checkinId: CHECKIN_ID,
          body: "Great spot",
          createdAt: "2026-09-22T10:00:00.000Z",
          user: { id: OTHER_USER_ID, name: "Alex", avatarUrl: null },
        },
      ],
    });
  });

  it("pages by a createdAt cursor", async () => {
    controls.queue([FRIENDS_CHECKIN], []);
    const response = await send("GET", `/${CHECKIN_ID}/comments?before=2026-09-22T10:00:00.000Z`);
    expect(response.status).toBe(200);

    // The second where is the comments query; the first found the checkin.
    const listed = dialect.sqlToQuery(argumentsOf("where")[1] as SQL);
    expect(listed.sql).toMatch(/"checkin_comments"\."created_at" < \$\d+/);
  });

  it("answers 404 for a checkin you cannot see", async () => {
    controls.queue([]);
    const response = await send("GET", `/${CHECKIN_ID}/comments`);
    expect(response.status).toBe(404);
  });
});

describe("POST /checkins/:id/comments", () => {
  it("adds a comment and tells the owner", async () => {
    controls.queue(
      [FRIENDS_CHECKIN],
      [commentRow()],
      [], // the notification insert
      [userRow({ id: CURRENT_USER_ID, name: "Sam" })],
    );

    const response = await send("POST", `/${CHECKIN_ID}/comments`, { body: "  Great spot  " });

    expect(response.status).toBe(201);
    expect(await response.json()).toMatchObject({
      id: COMMENT_ID,
      body: "Great spot",
      user: { id: CURRENT_USER_ID, name: "Sam" },
    });
    expect(controls.operations).toEqual(["select", "insert", "insert", "select"]);
    expect(argumentsOf("values")[0]).toEqual({
      checkinId: CHECKIN_ID,
      userId: CURRENT_USER_ID,
      body: "Great spot",
    });
    expect(argumentsOf("values")[1]).toEqual({
      recipientId: OTHER_USER_ID,
      actorId: CURRENT_USER_ID,
      kind: "comment",
      checkinId: CHECKIN_ID,
      commentId: COMMENT_ID,
    });
  });

  it("does not notify you about commenting on your own checkin", async () => {
    controls.queue([OWN_CHECKIN], [commentRow()], [userRow({ id: CURRENT_USER_ID })]);

    const response = await send("POST", `/${CHECKIN_ID}/comments`, { body: "Mine" });

    expect(response.status).toBe(201);
    expect(controls.operations).toEqual(["select", "insert", "select"]);
  });

  it("rejects an empty comment without touching the database", async () => {
    const response = await send("POST", `/${CHECKIN_ID}/comments`, { body: "   " });
    expect(response.status).toBe(400);
    expect(controls.operations).toEqual([]);
  });

  it("rejects a comment over 1000 characters", async () => {
    const response = await send("POST", `/${CHECKIN_ID}/comments`, { body: "x".repeat(1001) });
    expect(response.status).toBe(400);
  });

  it("answers 404 for a checkin you cannot see", async () => {
    controls.queue([]);
    const response = await send("POST", `/${CHECKIN_ID}/comments`, { body: "Hello" });
    expect(response.status).toBe(404);
    expect(controls.operations).toEqual(["select"]);
  });
});

describe("DELETE /checkins/:id/comments/:commentId", () => {
  it("deletes a comment that is yours or on your checkin", async () => {
    controls.queue([{ id: COMMENT_ID }]);

    const response = await send("DELETE", `/${CHECKIN_ID}/comments/${COMMENT_ID}`);

    expect(response.status).toBe(204);
    expect(controls.operations).toEqual(["delete"]);
    // Author or checkin owner, in one condition.
    const condition = dialect.sqlToQuery(argumentsOf("where")[0] as SQL);
    expect(condition.sql).toContain('"checkin_comments"."user_id" = $');
    expect(condition.sql).toContain("exists (");
    expect(condition.params.filter((param) => param === CURRENT_USER_ID)).toHaveLength(2);
  });

  // Someone else's comment on someone else's checkin, or no such comment:
  // the same 404 either way.
  it("answers 404 when nothing was deleted", async () => {
    controls.queue([]);
    const response = await send("DELETE", `/${CHECKIN_ID}/comments/${COMMENT_ID}`);
    expect(response.status).toBe(404);
  });

  it("rejects a malformed comment id", async () => {
    const response = await send("DELETE", `/${CHECKIN_ID}/comments/nope`);
    expect(response.status).toBe(400);
    expect(controls.operations).toEqual([]);
  });
});
