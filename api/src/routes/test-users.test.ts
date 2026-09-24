import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { createDatabaseStub } from "../../test/helpers/stub-database.js";
import { config } from "../config.js";

const { database, controls } = createDatabaseStub();

vi.mock("../db/index.js", () => ({ database }));

const { testUsers } = await import("./test-users.js");

const TEST_USER_ID = "7e570000-0000-4000-8000-000000000001";

function userRow(overrides: Record<string, unknown> = {}) {
  return {
    id: TEST_USER_ID,
    email: null,
    emailVerifiedAt: null,
    appleUserId: null,
    appleEmail: null,
    name: "Alice Testberg",
    bio: null,
    avatarKey: null,
    isTestUser: true,
    createdAt: new Date("2026-01-01T00:00:00.000Z"),
    updatedAt: new Date("2026-01-01T00:00:00.000Z"),
    ...overrides,
  };
}

function post(path: string) {
  return testUsers.request(path, { method: "POST" });
}

beforeEach(() => {
  controls.reset();
  config.ENABLE_TEST_USERS = true;
});

afterEach(() => {
  config.ENABLE_TEST_USERS = false;
});

describe("when ENABLE_TEST_USERS is off", () => {
  // These routes hand out sessions with no credential, so with the flag off
  // every one of them must look like it does not exist.
  it("answers every route with 404 without touching the database", async () => {
    config.ENABLE_TEST_USERS = false;

    const responses = await Promise.all([
      testUsers.request("/"),
      post("/"),
      post(`/${TEST_USER_ID}/session`),
    ]);

    expect(responses.map((response) => response.status)).toEqual([404, 404, 404]);
    expect(controls.operations).toEqual([]);
  });
});

describe("GET /", () => {
  it("lists test users as summaries", async () => {
    controls.queue([userRow(), userRow({ id: "7e570000-0000-4000-8000-000000000002", name: null })]);

    const response = await testUsers.request("/");

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({
      results: [
        { id: TEST_USER_ID, name: "Alice Testberg", avatarUrl: null },
        { id: "7e570000-0000-4000-8000-000000000002", name: null, avatarUrl: null },
      ],
    });
  });
});

describe("POST /", () => {
  it("creates a nameless test user and signs them in", async () => {
    controls.queue([userRow({ name: null })], []); // batch: insert user, insert session

    const response = await post("/");
    const body = (await response.json()) as Record<string, unknown>;

    expect(response.status).toBe(201);
    expect(body.user).toMatchObject({ id: TEST_USER_ID, name: null });
    expect(body.accessToken).toEqual(expect.any(String));
    expect(body.refreshToken).toEqual(expect.any(String));
    expect(controls.operations).toEqual(["insert", "insert", "batch"]);
  });
});

describe("POST /:id/session", () => {
  it("signs in as a test user", async () => {
    controls.queue([userRow()], []);

    const response = await post(`/${TEST_USER_ID}/session`);
    const body = (await response.json()) as Record<string, unknown>;

    expect(response.status).toBe(200);
    expect(body.user).toMatchObject({ id: TEST_USER_ID, name: "Alice Testberg" });
    expect(body.accessToken).toEqual(expect.any(String));
    expect(controls.operations).toEqual(["select", "insert"]);
  });

  // The lookup is filtered to test users, so a real account's id comes back
  // empty and gets the same 404 as an id that does not exist.
  it("answers an id that is not a test user with 404 and creates no session", async () => {
    controls.queue([]);

    const response = await post("/550e8400-e29b-41d4-a716-446655440000/session");

    expect(response.status).toBe(404);
    expect(await response.json()).toEqual({ error: "Test user not found" });
    expect(controls.operations).toEqual(["select"]);
  });

  it("rejects an id that is not a uuid", async () => {
    const response = await post("/alice/session");

    expect(response.status).toBe(400);
    expect(controls.operations).toEqual([]);
  });
});
