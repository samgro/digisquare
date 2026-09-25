import { beforeEach, describe, expect, it, vi } from "vitest";
import { createDatabaseStub } from "../../test/helpers/stub-database.js";
import { hashRefreshToken } from "../lib/tokens.js";

const { database, controls } = createDatabaseStub();

vi.mock("../db/index.js", () => ({ database }));

const { auth } = await import("./auth.js");

const USER_ID = "550e8400-e29b-41d4-a716-446655440000";
const FAMILY_ID = "33333333-3333-3333-3333-333333333333";
const SESSION_ID = "22222222-2222-2222-2222-222222222222";

/** A rate-limit upsert result that leaves the caller under the limit. */
const UNDER_LIMIT = [{ attemptCount: 1 }];

function userRow(overrides: Record<string, unknown> = {}) {
  return {
    id: USER_ID,
    email: "someone@example.com",
    emailVerifiedAt: null,
    appleUserId: null,
    appleEmail: null,
    name: "Someone",
    bio: null,
    avatarKey: null,
    isTestUser: false,
    hometown: null,
    createdAt: new Date("2026-01-01T00:00:00.000Z"),
    updatedAt: new Date("2026-01-01T00:00:00.000Z"),
    ...overrides,
  };
}

function sessionRow(overrides: Record<string, unknown> = {}) {
  return {
    id: SESSION_ID,
    userId: USER_ID,
    familyId: FAMILY_ID,
    familyStartedAt: new Date(),
    refreshTokenHash: hashRefreshToken("a-token"),
    replacedBySessionId: null,
    expiresAt: new Date(Date.now() + 60 * 86_400_000),
    rotatedAt: null,
    revokedAt: null,
    revokedReason: null,
    userAgent: null,
    ipAddress: null,
    createdAt: new Date(),
    ...overrides,
  };
}

function post(path: string, body: unknown) {
  return auth.request(path, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
}

beforeEach(() => {
  controls.reset();
});

describe("POST /refresh", () => {
  it("rotates and returns a different refresh token", async () => {
    controls.queue(
      UNDER_LIMIT,
      [sessionRow()], // the claim succeeds
      [],
      [], // batch: insert successor, update predecessor
    );

    const response = await post("/refresh", { refreshToken: "a-token" });
    expect(response.status).toBe(200);

    const body = (await response.json()) as Record<string, unknown>;
    expect(body.refreshToken).toBeTypeOf("string");
    expect(body.refreshToken).not.toBe("a-token");
    expect(body.accessToken).toBeTypeOf("string");
    // Refresh is a hot path; it deliberately does not re-send the profile.
    expect(body.user).toBeUndefined();
  });

  // Replaying a spent token is what a stolen-token attack looks like, so the
  // whole family is revoked rather than just that one session.
  it("revokes the family when a rotated token is replayed", async () => {
    const longAgo = new Date(Date.now() - 10 * 60_000);
    controls.queue(
      UNDER_LIMIT,
      [], // the claim finds nothing
      [sessionRow({ rotatedAt: longAgo, replacedBySessionId: null })],
      [],
    );

    const response = await post("/refresh", { refreshToken: "a-token" });

    expect(response.status).toBe(401);
    expect(await response.json()).toEqual({ error: "Invalid refresh token" });
    // select (diagnosis) then update (revoke the family).
    expect(controls.operations).toEqual(["insert", "update", "select", "update"]);
  });

  // An unknown token must revoke nothing. If it did, anyone could sign a user
  // out by posting garbage, turning the defence into a denial of service.
  it("revokes nothing for a token that was never issued", async () => {
    controls.queue(UNDER_LIMIT, [], []);

    const response = await post("/refresh", { refreshToken: "never-issued" });

    expect(response.status).toBe(401);
    // No second update: the diagnosis select found nothing to revoke.
    expect(controls.operations).toEqual(["insert", "update", "select"]);
  });

  // The other half of that guard, and the one a mutation test caught as
  // uncovered: a token that IS in the table but was never rotated or revoked —
  // an expired one, say — is not a replay either, so it must not burn the
  // family. Checking only for absence would let an expired token sign a user
  // out of every device.
  it("revokes nothing for a token that exists but was never used", async () => {
    const expired = sessionRow({
      rotatedAt: null,
      revokedAt: null,
      expiresAt: new Date(Date.now() - 86_400_000),
    });
    controls.queue(UNDER_LIMIT, [], [expired]);

    const response = await post("/refresh", { refreshToken: "a-token" });

    expect(response.status).toBe(401);
    expect(await response.json()).toEqual({ error: "Invalid refresh token" });
    // The diagnosis select ran, but no revoking update followed it.
    expect(controls.operations).toEqual(["insert", "update", "select"]);
  });

  // A token rotated seconds ago is far more likely to be an honest retry after
  // a dropped response than an attack, so the successor is rotated instead.
  it("treats a replay inside the grace window as an honest retry", async () => {
    const justNow = new Date(Date.now() - 2_000);
    controls.queue(
      UNDER_LIMIT,
      [], // claim finds nothing
      [sessionRow({ rotatedAt: justNow, replacedBySessionId: "44444444-4444-4444-4444-444444444444" })],
      [sessionRow({ id: "44444444-4444-4444-4444-444444444444" })], // successor claimed
      [],
      [],
    );

    const response = await post("/refresh", { refreshToken: "a-token" });

    expect(response.status).toBe(200);
    expect(controls.operations).not.toContain("delete");
  });

  it("rejects a session whose family has outlived the absolute cap", async () => {
    const longPast = new Date(Date.now() - 365 * 86_400_000);
    controls.queue(UNDER_LIMIT, [sessionRow({ familyStartedAt: longPast })], []);

    const response = await post("/refresh", { refreshToken: "a-token" });

    expect(response.status).toBe(401);
    expect(await response.json()).toEqual({ error: "Session expired" });
  });
});

describe("POST /logout", () => {
  // Reporting whether a token was real would make this an oracle.
  it("returns 204 for an unknown token", async () => {
    controls.queue([]);
    const response = await post("/logout", { refreshToken: "never-issued" });
    expect(response.status).toBe(204);
  });

  it("returns 204 for a malformed body rather than an error", async () => {
    const response = await post("/logout", { refreshToken: "" });
    expect(response.status).toBe(204);
  });

  it("revokes the family for a real token", async () => {
    controls.queue([{ familyId: FAMILY_ID }], []);
    const response = await post("/logout", { refreshToken: "a-token" });
    expect(response.status).toBe(204);
    expect(controls.operations).toEqual(["select", "update"]);
  });
});
