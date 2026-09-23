import { describe, expect, it, vi } from "vitest";

vi.mock("../db/index.js", () => ({ database: {} }));

const { toFriendshipState } = await import("./friendships.js");

const REQUESTER_ID = "550e8400-e29b-41d4-a716-446655440000";
const ADDRESSEE_ID = "660e8400-e29b-41d4-a716-446655440000";
const REQUEST_ID = "770e8400-e29b-41d4-a716-446655440000";

function friendshipRow(status: "pending" | "accepted" | "declined") {
  return {
    id: REQUEST_ID,
    requesterId: REQUESTER_ID,
    addresseeId: ADDRESSEE_ID,
    status,
    createdAt: new Date("2026-02-01T00:00:00.000Z"),
    updatedAt: new Date("2026-02-01T00:00:00.000Z"),
  };
}

describe("toFriendshipState", () => {
  // The requester is never told they were declined, so they can still cancel.
  it("shows a declined request to its requester as still pending", () => {
    expect(toFriendshipState(friendshipRow("declined"), REQUESTER_ID)).toEqual({
      status: "outgoingRequest",
      friendRequestId: REQUEST_ID,
    });
  });

  it("shows a declined request to its addressee as no relationship", () => {
    expect(toFriendshipState(friendshipRow("declined"), ADDRESSEE_ID)).toEqual({
      status: "none",
      friendRequestId: null,
    });
  });

  it("shows a pending request to its addressee as incoming", () => {
    expect(toFriendshipState(friendshipRow("pending"), ADDRESSEE_ID)).toEqual({
      status: "incomingRequest",
      friendRequestId: REQUEST_ID,
    });
  });
});
