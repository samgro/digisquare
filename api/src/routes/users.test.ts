import { beforeEach, describe, expect, it, vi } from "vitest";
import { createDatabaseStub } from "../../test/helpers/stub-database.js";
import { createAccessToken } from "../lib/tokens.js";

const { database, controls } = createDatabaseStub();

vi.mock("../db/index.js", () => ({ database }));

const { users } = await import("./users.js");

const CURRENT_USER_ID = "550e8400-e29b-41d4-a716-446655440000";
const OTHER_USER_ID = "660e8400-e29b-41d4-a716-446655440000";
const REQUEST_ID = "770e8400-e29b-41d4-a716-446655440000";
const SESSION_ID = "22222222-2222-2222-2222-222222222222";

const accessToken = await createAccessToken(CURRENT_USER_ID, SESSION_ID);

function userRow(overrides: Record<string, unknown> = {}) {
  return {
    id: OTHER_USER_ID,
    email: "alex@example.com",
    emailVerifiedAt: null,
    passwordHash: "hash",
    appleUserId: null,
    appleEmail: null,
    name: "Alex",
    bio: null,
    avatarKey: null,
    createdAt: new Date("2026-01-01T00:00:00.000Z"),
    updatedAt: new Date("2026-01-01T00:00:00.000Z"),
    ...overrides,
  };
}

function friendshipRow(overrides: Record<string, unknown> = {}) {
  return {
    id: REQUEST_ID,
    requesterId: CURRENT_USER_ID,
    addresseeId: OTHER_USER_ID,
    status: "pending",
    createdAt: new Date("2026-02-01T00:00:00.000Z"),
    updatedAt: new Date("2026-02-01T00:00:00.000Z"),
    ...overrides,
  };
}

function get(path: string) {
  return users.request(path, { headers: { Authorization: `Bearer ${accessToken}` } });
}

beforeEach(() => {
  controls.reset();
});

describe("GET /search", () => {
  // /:id is registered on the same router and validates its param as a uuid.
  // If it were matched first, every search would be a 400 "Invalid user id".
  it("is routed to search rather than read as a user id", async () => {
    controls.queue([]);

    const response = await get("/search?q=alex");

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ results: [] });
  });

  it("rejects an empty query", async () => {
    const response = await get("/search?q=%20%20");
    expect(response.status).toBe(400);
    expect(controls.operations).toEqual([]);
  });

  it("rejects an overlong query", async () => {
    const response = await get(`/search?q=${"a".repeat(61)}`);
    expect(response.status).toBe(400);
  });

  it("labels each result with how you relate to them", async () => {
    const strangerId = "990e8400-e29b-41d4-a716-446655440000";
    const friendId = "aa0e8400-e29b-41d4-a716-446655440000";
    const requesterId = "bb0e8400-e29b-41d4-a716-446655440000";
    controls.queue(
      [
        userRow(),
        userRow({ id: strangerId, name: "Alexa" }),
        userRow({ id: friendId, name: "Alexander" }),
        userRow({ id: requesterId, name: "Alexis" }),
      ],
      [
        friendshipRow(),
        friendshipRow({
          id: "cc0e8400-e29b-41d4-a716-446655440000",
          requesterId: friendId,
          addresseeId: CURRENT_USER_ID,
          status: "accepted",
        }),
        friendshipRow({
          id: "dd0e8400-e29b-41d4-a716-446655440000",
          requesterId,
          addresseeId: CURRENT_USER_ID,
        }),
      ],
    );

    const response = await get("/search?q=alex");
    const body = (await response.json()) as { results: Record<string, unknown>[] };

    expect(
      body.results.map((result) => [
        result.name,
        result.friendshipStatus,
        result.friendRequestId,
      ]),
    ).toEqual([
      ["Alex", "outgoingRequest", REQUEST_ID],
      ["Alexa", "none", null],
      ["Alexander", "friends", null],
      ["Alexis", "incomingRequest", "dd0e8400-e29b-41d4-a716-446655440000"],
    ]);
    expect(JSON.stringify(body)).not.toContain("@example.com");
  });
});

describe("GET /:id", () => {
  it("includes the checkin and friend counts and friendship status", async () => {
    controls.queue([userRow()], [{ value: 12 }], [{ value: 3 }], [friendshipRow({ status: "accepted" })]);

    const response = await get(`/${OTHER_USER_ID}`);

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({
      id: OTHER_USER_ID,
      name: "Alex",
      bio: null,
      avatarUrl: null,
      createdAt: "2026-01-01T00:00:00.000Z",
      checkinCount: 12,
      friendCount: 3,
      friendshipStatus: "friends",
      friendRequestId: null,
    });
  });

  it("answers 404 for an unknown user", async () => {
    controls.queue([]);

    const response = await get(`/${OTHER_USER_ID}`);

    expect(response.status).toBe(404);
    expect(controls.operations).toEqual(["select"]);
  });
});
