import { beforeEach, describe, expect, it, vi } from "vitest";
import { createDatabaseStub } from "../test/helpers/stub-database.js";

const { database } = createDatabaseStub();
vi.mock("./db/index.js", () => ({ database }));

const identity = vi.hoisted(() => ({ currentBuildIdentity: vi.fn() }));
vi.mock("./lib/build-identity.js", async (importOriginal) => ({
  ...(await importOriginal<typeof import("./lib/build-identity.js")>()),
  currentBuildIdentity: identity.currentBuildIdentity,
}));

const { app } = await import("./app.js");

beforeEach(() => {
  identity.currentBuildIdentity.mockReset();
});

describe("GET /", () => {
  it("reports the server's build so the app can check before signing in", async () => {
    identity.currentBuildIdentity.mockResolvedValue({ branch: "claude/places", commit: "7e1389e", source: "git" });
    const response = await app.request("/");
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ status: "ok", build: { branch: "claude/places", commit: "7e1389e" } });
    expect(response.headers.get("X-Hackysack-Build")).toBe("claude/places@7e1389e");
  });

  it("reports no build where none is known", async () => {
    identity.currentBuildIdentity.mockResolvedValue(null);
    expect(await (await app.request("/")).json()).toEqual({ status: "ok", build: null });
  });

  it("gates every route, not just the root", async () => {
    identity.currentBuildIdentity.mockResolvedValue({ branch: "claude/places", commit: "7e1389e", source: "git" });
    const response = await app.request("/places?lat=1&lng=1", { headers: { "X-Hackysack-Client-Build": "other@1234567" } });
    expect(response.status).toBe(409);
  });
});
