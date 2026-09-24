import { beforeEach, describe, expect, it, vi } from "vitest";
import { createDatabaseStub } from "../../test/helpers/stub-database.js";
import { createAccessToken } from "../lib/tokens.js";

const { database, controls } = createDatabaseStub();

vi.mock("../db/index.js", () => ({ database }));

const { notifications } = await import("./notifications.js");

const CURRENT_USER_ID = "550e8400-e29b-41d4-a716-446655440000";
const OTHER_USER_ID = "660e8400-e29b-41d4-a716-446655440000";
const CHECKIN_ID = "880e8400-e29b-41d4-a716-446655440000";
const NOTIFICATION_ID = "bb0e8400-e29b-41d4-a716-446655440000";
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
    bio: null,
    avatarKey: null,
    isTestUser: false,
    createdAt: new Date("2026-01-01T00:00:00.000Z"),
    updatedAt: new Date("2026-01-01T00:00:00.000Z"),
    ...overrides,
  };
}

function notificationRow(overrides: Record<string, unknown> = {}) {
  return {
    id: NOTIFICATION_ID,
    recipientId: CURRENT_USER_ID,
    actorId: OTHER_USER_ID,
    kind: "like",
    checkinId: CHECKIN_ID,
    commentId: null,
    friendshipId: null,
    readAt: null,
    createdAt: new Date("2026-09-22T10:00:00.000Z"),
    ...overrides,
  };
}

function send(method: string, path: string) {
  return notifications.request(path, {
    method,
    headers: { Authorization: `Bearer ${accessToken}` },
  });
}

beforeEach(() => {
  controls.reset();
});

describe("authentication", () => {
  it("rejects a request without a bearer token", async () => {
    const response = await notifications.request("/");
    expect(response.status).toBe(401);
    expect(controls.operations).toEqual([]);
  });
});

describe("GET /notifications", () => {
  it("lists the feed with each subject and the unread count", async () => {
    controls.queue(
      [
        {
          notification: notificationRow(),
          actor: userRow(),
          checkin: { id: CHECKIN_ID, placeName: "Blue Bottle" },
          comment: null,
          friendship: null,
        },
        {
          notification: notificationRow({
            id: "cc0e8400-e29b-41d4-a716-446655440000",
            kind: "friend_request",
            checkinId: null,
            friendshipId: "770e8400-e29b-41d4-a716-446655440000",
          }),
          actor: userRow(),
          checkin: null,
          comment: null,
          friendship: { id: "770e8400-e29b-41d4-a716-446655440000", status: "pending" },
        },
      ],
      [{ value: 2 }],
    );

    const response = await send("GET", "/");

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({
      results: [
        {
          id: NOTIFICATION_ID,
          kind: "like",
          actor: { id: OTHER_USER_ID, name: "Alex", avatarUrl: null },
          checkin: { id: CHECKIN_ID, placeName: "Blue Bottle" },
          comment: null,
          friendship: null,
          readAt: null,
          createdAt: "2026-09-22T10:00:00.000Z",
        },
        {
          id: "cc0e8400-e29b-41d4-a716-446655440000",
          kind: "friend_request",
          actor: { id: OTHER_USER_ID, name: "Alex", avatarUrl: null },
          checkin: null,
          comment: null,
          friendship: { id: "770e8400-e29b-41d4-a716-446655440000", status: "pending" },
          readAt: null,
          createdAt: "2026-09-22T10:00:00.000Z",
        },
      ],
      unreadCount: 2,
    });
    expect(controls.operations).toEqual(["select", "select"]);
  });

  it("rejects a before that is not a timestamp", async () => {
    const response = await send("GET", "/?before=nope");
    expect(response.status).toBe(400);
    expect(controls.operations).toEqual([]);
  });

  it("rejects an out-of-range limit", async () => {
    const response = await send("GET", "/?limit=500");
    expect(response.status).toBe(400);
  });
});

describe("GET /notifications/unread-count", () => {
  it("returns the count", async () => {
    controls.queue([{ value: 3 }]);
    const response = await send("GET", "/unread-count");
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ unreadCount: 3 });
  });

  it("reads zero when there is no row", async () => {
    controls.queue([]);
    const response = await send("GET", "/unread-count");
    expect(await response.json()).toEqual({ unreadCount: 0 });
  });
});

describe("POST /notifications/read", () => {
  it("marks everything read in one update", async () => {
    controls.queue([]);
    const response = await send("POST", "/read");
    expect(response.status).toBe(204);
    expect(controls.operations).toEqual(["update"]);
  });
});
