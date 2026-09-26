import { Hono } from "hono";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { AppEnv } from "../types.js";

const identity = vi.hoisted(() => ({ currentBuildIdentity: vi.fn() }));
vi.mock("../lib/build-identity.js", async (importOriginal) => ({
  ...(await importOriginal<typeof import("../lib/build-identity.js")>()),
  currentBuildIdentity: identity.currentBuildIdentity,
}));

const { buildGate, BUILD_HEADER, CLIENT_BUILD_HEADER } = await import("./build-gate.js");

const app = new Hono<AppEnv>();
app.use("*", buildGate);
app.get("/ping", (context) => context.json({ ok: true }));

const SERVER = { branch: "claude/places", commit: "7e1389e", source: "git" as const };

function ping(clientBuild?: string) {
  return app.request("/ping", clientBuild ? { headers: { [CLIENT_BUILD_HEADER]: clientBuild } } : undefined);
}

beforeEach(() => {
  identity.currentBuildIdentity.mockReset().mockResolvedValue(SERVER);
});

describe("buildGate", () => {
  it("names the server's build on every response", async () => {
    const response = await ping();
    expect(response.status).toBe(200);
    expect(response.headers.get(BUILD_HEADER)).toBe("claude/places@7e1389e");
  });

  it("lets a client from the same branch and commit through", async () => {
    expect((await ping("claude/places@7e1389e")).status).toBe(200);
  });

  it("lets a client from the same branch but another commit through, header included", async () => {
    const response = await ping("claude/places@0000000");
    expect(response.status).toBe(200);
    expect(response.headers.get(BUILD_HEADER)).toBe("claude/places@7e1389e");
  });

  it("refuses a client from another branch before the route runs, naming both builds", async () => {
    const response = await ping("claude/other-feature@abcdef0");
    expect(response.status).toBe(409);
    expect(await response.json()).toEqual({
      error: "This app was built from claude/other-feature@abcdef0, but this server is running claude/places@7e1389e.",
      code: "build_mismatch",
      server: { branch: "claude/places", commit: "7e1389e" },
      client: { branch: "claude/other-feature", commit: "abcdef0" },
    });
  });

  it("splits the client build on its last @, so a branch may contain one", async () => {
    identity.currentBuildIdentity.mockResolvedValue({ ...SERVER, branch: "sam@work/gate" });
    expect((await ping("sam@work/gate@1234567")).status).toBe(200);
    expect((await ping("sam@home/gate@1234567")).status).toBe(409);
  });

  it("ignores a client header it cannot parse", async () => {
    expect((await ping("garbage")).status).toBe(200);
  });

  it("never refuses when the server's identity came from Railway", async () => {
    identity.currentBuildIdentity.mockResolvedValue({ branch: "main", commit: "1234567", source: "railway" });
    const response = await ping("claude/other-feature@abcdef0");
    expect(response.status).toBe(200);
    expect(response.headers.get(BUILD_HEADER)).toBe("main@1234567");
  });

  it("does nothing when the server has no identity at all", async () => {
    identity.currentBuildIdentity.mockResolvedValue(null);
    const response = await ping("claude/other-feature@abcdef0");
    expect(response.status).toBe(200);
    expect(response.headers.get(BUILD_HEADER)).toBeNull();
  });
});
