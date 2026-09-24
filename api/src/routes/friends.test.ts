import type { SQL } from "drizzle-orm";
import { PgDialect } from "drizzle-orm/pg-core";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { DrizzleQueryError } from "drizzle-orm/errors";
import { createDatabaseStub } from "../../test/helpers/stub-database.js";
import { createAccessToken } from "../lib/tokens.js";

const { database, controls } = createDatabaseStub();

vi.mock("../db/index.js", () => ({ database }));

const { friends } = await import("./friends.js");

const CURRENT_USER_ID = "550e8400-e29b-41d4-a716-446655440000";
const OTHER_USER_ID = "660e8400-e29b-41d4-a716-446655440000";
const REQUEST_ID = "770e8400-e29b-41d4-a716-446655440000";
const SESSION_ID = "22222222-2222-2222-2222-222222222222";

const accessToken = await createAccessToken(CURRENT_USER_ID, SESSION_ID);

function userRow(overrides: Record<string, unknown> = {}) {
  return {
    id: OTHER_USER_ID,
    email: "friend@example.com",
    emailVerifiedAt: null,
    appleUserId: null,
    appleEmail: null,
    name: "Alex",
    bio: "Coffee first",
    avatarKey: null,
    isTestUser: false,
    createdAt: new Date("2026-01-01T00:00:00.000Z"),
    updatedAt: new Date("2026-01-01T00:00:00.000Z"),
    ...overrides,
  };
}

function friendshipRow(overrides: Record<string, unknown> = {}) {
  return {
    id: REQUEST_ID,
    requesterId: OTHER_USER_ID,
    addresseeId: CURRENT_USER_ID,
    status: "pending",
    createdAt: new Date("2026-02-01T00:00:00.000Z"),
    updatedAt: new Date("2026-02-01T00:00:00.000Z"),
    ...overrides,
  };
}

function send(method: string, path: string, body?: unknown) {
  return friends.request(path, {
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

function uniqueViolation() {
  return new DrizzleQueryError(
    "insert into friendships",
    [],
    Object.assign(new Error("duplicate key value"), { code: "23505" }),
  );
}

beforeEach(() => {
  controls.reset();
});

describe("authentication", () => {
  it("rejects a request without a bearer token", async () => {
    const response = await friends.request("/requests");
    expect(response.status).toBe(401);
    expect(controls.operations).toEqual([]);
  });
});

describe("GET /requests", () => {
  it("returns incoming requests with the requester's public profile", async () => {
    controls.queue([{ friendship: friendshipRow(), user: userRow() }]);

    const response = await send("GET", "/requests");

    expect(response.status).toBe(200);
    const body = (await response.json()) as { results: Record<string, unknown>[] };
    expect(body.results).toHaveLength(1);
    expect(body.results[0].id).toBe(REQUEST_ID);
    expect(body.results[0].user).toEqual({
      id: OTHER_USER_ID,
      name: "Alex",
      bio: "Coffee first",
      avatarUrl: null,
      createdAt: "2026-01-01T00:00:00.000Z",
    });
    // The requester's email must never leak into a friend request.
    expect(JSON.stringify(body)).not.toContain("friend@example.com");
  });
});

describe("GET /checkins", () => {
  it("attaches a summary of the owner to each checkin", async () => {
    controls.queue([
      {
        checkin: {
          id: "880e8400-e29b-41d4-a716-446655440000",
          userId: OTHER_USER_ID,
          placeId: "990e8400-e29b-41d4-a716-446655440000",
          placeName: "Blue Bottle",
          placeAddress: null,
          placeLocality: null,
          placePrimaryType: "cafe",
          placeTypes: null,
          latitude: null,
          longitude: null,
          message: null,
          createdAt: new Date("2026-03-01T00:00:00.000Z"),
          updatedAt: new Date("2026-03-01T00:00:00.000Z"),
        },
        user: userRow(),
      },
    ]);

    const response = await send("GET", "/checkins");

    expect(response.status).toBe(200);
    const body = (await response.json()) as { results: Record<string, unknown>[] };
    expect(body.results[0].placeName).toBe("Blue Bottle");
    expect(body.results[0].user).toEqual({ id: OTHER_USER_ID, name: "Alex", avatarUrl: null });
    // The stub row carries no counts, which the result reads as none.
    expect(body.results[0]).toMatchObject({ likeCount: 0, commentCount: 0, likedByMe: false });
  });

  it("pages by a createdAt cursor rather than an offset", async () => {
    controls.queue([]);
    const response = await send("GET", "/checkins?limit=10&before=2026-03-01T00:00:00.000Z");
    expect(response.status).toBe(200);

    const whereCall = controls.chainedCalls.find((call) => call.method === "where");
    const condition = new PgDialect().sqlToQuery(whereCall?.arguments[0] as SQL);
    expect(condition.sql).toMatch(/"checkins"\."created_at" < \$\d+/);
    expect(condition.params).toContain("2026-03-01T00:00:00.000Z");
    expect(controls.chainedCalls.map((call) => call.method)).not.toContain("offset");
  });

  it("rejects a before that is not a timestamp", async () => {
    const response = await send("GET", "/checkins?before=yesterday");
    expect(response.status).toBe(400);
    expect(controls.operations).toEqual([]);
  });

  it("leaves private checkins out, including the caller's own", async () => {
    controls.queue([]);
    const response = await send("GET", "/checkins");
    expect(response.status).toBe(200);

    const whereCall = controls.chainedCalls.find((call) => call.method === "where");
    const condition = new PgDialect().sqlToQuery(whereCall?.arguments[0] as SQL);
    // The visibility check applies to the whole condition, not only to friends'.
    expect(condition.sql).toMatch(/\) and "checkins"\."visibility" = \$\d+\)$/);
    expect(condition.params).toContain("friends");
  });

  it("rejects an out-of-range limit", async () => {
    const response = await send("GET", "/checkins?limit=500");
    expect(response.status).toBe(400);
  });
});

describe("POST /requests", () => {
  it("refuses a request to yourself without touching the database", async () => {
    const response = await send("POST", "/requests", { userId: CURRENT_USER_ID });

    expect(response.status).toBe(400);
    expect(controls.operations).toEqual([]);
  });

  it("rejects a malformed user id", async () => {
    const response = await send("POST", "/requests", { userId: "not-a-uuid" });
    expect(response.status).toBe(400);
  });

  it("answers 404 for a user that does not exist", async () => {
    controls.queue([]);

    const response = await send("POST", "/requests", { userId: OTHER_USER_ID });

    expect(response.status).toBe(404);
    expect(controls.operations).toEqual(["select"]);
  });

  it("creates a pending request", async () => {
    controls.queue(
      [{ id: OTHER_USER_ID }], // the user exists
      [], // they have not asked you
      [friendshipRow({ requesterId: CURRENT_USER_ID, addresseeId: OTHER_USER_ID })],
    );

    const response = await send("POST", "/requests", { userId: OTHER_USER_ID });

    expect(response.status).toBe(201);
    expect(await response.json()).toEqual({ id: REQUEST_ID, status: "pending" });
    // The second insert is the request's notification for the addressee.
    expect(controls.operations).toEqual(["select", "update", "insert", "insert"]);
    expect(argumentsOf("values")[1]).toEqual({
      recipientId: OTHER_USER_ID,
      actorId: CURRENT_USER_ID,
      kind: "friend_request",
      friendshipId: REQUEST_ID,
    });
  });

  // Adding someone who already asked you is an answer to their request, not a
  // second request that would sit waiting on both sides.
  it("accepts their pending request instead of sending one back", async () => {
    controls.queue([{ id: OTHER_USER_ID }], [friendshipRow({ status: "accepted" })]);

    const response = await send("POST", "/requests", { userId: OTHER_USER_ID });

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ id: REQUEST_ID, status: "accepted" });
    // Their request notification is retired and they hear it was accepted.
    expect(controls.operations).toEqual(["select", "update", "delete", "insert"]);
    expect(argumentsOf("values")[0]).toEqual({
      recipientId: OTHER_USER_ID,
      actorId: CURRENT_USER_ID,
      kind: "friend_accepted",
      friendshipId: REQUEST_ID,
    });
  });

  // Adding someone whose request you declined takes the decline back.
  it("accepts a request you previously declined", async () => {
    controls.queue([{ id: OTHER_USER_ID }], [friendshipRow({ status: "accepted" })]);

    const response = await send("POST", "/requests", { userId: OTHER_USER_ID });

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ id: REQUEST_ID, status: "accepted" });
    expect(controls.operations).toEqual(["select", "update", "delete", "insert"]);
  });

  it("answers 409 when the pair already has a request or friendship", async () => {
    controls.queue([{ id: OTHER_USER_ID }], []);
    controls.queueFailure(uniqueViolation());

    const response = await send("POST", "/requests", { userId: OTHER_USER_ID });

    expect(response.status).toBe(409);
    expect(await response.json()).toEqual({ error: "Friend request already exists" });
  });
});

describe("POST /requests/:id/accept", () => {
  it("accepts a request addressed to you", async () => {
    controls.queue([friendshipRow({ status: "accepted" })]);

    const response = await send("POST", `/requests/${REQUEST_ID}/accept`);

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ id: REQUEST_ID, status: "accepted" });
    expect(controls.operations).toEqual(["update", "delete", "insert"]);
    expect(argumentsOf("values")[0]).toMatchObject({
      recipientId: OTHER_USER_ID,
      kind: "friend_accepted",
    });
  });

  // Covers a request that doesn't exist, one you sent (only the addressee can
  // accept) and one already answered: all are the same 404.
  it("answers 404 when there is no pending request for you to accept", async () => {
    controls.queue([]);

    const response = await send("POST", `/requests/${REQUEST_ID}/accept`);

    expect(response.status).toBe(404);
  });

  it("rejects a malformed request id", async () => {
    const response = await send("POST", "/requests/nope/accept");
    expect(response.status).toBe(400);
  });
});

describe("DELETE /requests/:id", () => {
  // Declining keeps the row so the requester still sees "Requested" and
  // never learns they were declined.
  it("declines a request you received without deleting it", async () => {
    controls.queue([{ id: REQUEST_ID }]);

    const response = await send("DELETE", `/requests/${REQUEST_ID}`);

    expect(response.status).toBe(204);
    // The delete is the request's notification, not the friendship row.
    expect(controls.operations).toEqual(["update", "delete"]);
  });

  it("cancels a request you sent by deleting it", async () => {
    controls.queue([], [{ id: REQUEST_ID }]);

    const response = await send("DELETE", `/requests/${REQUEST_ID}`);

    expect(response.status).toBe(204);
    expect(controls.operations).toEqual(["update", "delete"]);
  });

  it("answers 404 when there is no such request of yours", async () => {
    controls.queue([], []);

    const response = await send("DELETE", `/requests/${REQUEST_ID}`);

    expect(response.status).toBe(404);
  });
});

describe("DELETE /:id", () => {
  it("removes a friend", async () => {
    controls.queue([{ id: REQUEST_ID }]);

    const response = await send("DELETE", `/${OTHER_USER_ID}`);

    expect(response.status).toBe(204);
  });

  it("answers 404 when you are not friends", async () => {
    controls.queue([]);

    const response = await send("DELETE", `/${OTHER_USER_ID}`);

    expect(response.status).toBe(404);
    expect(await response.json()).toEqual({ error: "Friend not found" });
  });

  it("rejects a malformed user id", async () => {
    const response = await send("DELETE", "/nope");
    expect(response.status).toBe(400);
  });
});
