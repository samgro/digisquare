import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { createDatabaseStub } from "../../test/helpers/stub-database.js";
import { stubFetch, type StubbedFetch } from "../../test/helpers/stub-fetch.js";
import { createAccessToken, createOAuthStateToken, verifyOAuthStateToken } from "../lib/tokens.js";

const { database, controls } = createDatabaseStub();
const startSwarmImport = vi.fn();

vi.mock("../db/index.js", () => ({ database }));
vi.mock("../lib/swarm-import.js", () => ({ startSwarmImport }));

const { swarmImports } = await import("./swarm-imports.js");

const CURRENT_USER_ID = "550e8400-e29b-41d4-a716-446655440000";
const IMPORT_ID = "990e8400-e29b-41d4-a716-446655440000";
const SESSION_ID = "22222222-2222-2222-2222-222222222222";

const accessToken = await createAccessToken(CURRENT_USER_ID, SESSION_ID);

function importRow(overrides: Record<string, unknown> = {}) {
  return {
    id: IMPORT_ID,
    userId: CURRENT_USER_ID,
    status: "running",
    phase: "checkins",
    beforeTimestamp: null,
    afterTimestamp: null,
    checkinsImported: 250,
    photosTotal: 0,
    photosCopied: 0,
    error: null,
    startedAt: new Date("2026-09-24T00:00:00.000Z"),
    finishedAt: null,
    ...overrides,
  };
}

function send(method: string, path: string) {
  return swarmImports.request(path, {
    method,
    headers: { Authorization: `Bearer ${accessToken}` },
  });
}

function callback(query: Record<string, string>) {
  return swarmImports.request(`/callback?${new URLSearchParams(query)}`);
}

let fetchStub: StubbedFetch | undefined;

beforeEach(() => {
  controls.reset();
  startSwarmImport.mockReset();
});

afterEach(() => {
  fetchStub?.restore();
  fetchStub = undefined;
});

describe("POST /authorization", () => {
  it("returns a Foursquare url whose state names the caller", async () => {
    const response = await send("POST", "/authorization");

    expect(response.status).toBe(200);
    const body = (await response.json()) as { authorizationUrl: string };
    const state = new URL(body.authorizationUrl).searchParams.get("state")!;
    expect(await verifyOAuthStateToken(state, "foursquare")).toBe(CURRENT_USER_ID);
  });

  it("requires auth", async () => {
    const response = await swarmImports.request("/authorization", { method: "POST" });
    expect(response.status).toBe(401);
  });
});

describe("GET /callback", () => {
  it("connects the account, starts the import and returns to the app", async () => {
    fetchStub = stubFetch([
      { match: "foursquare.com/oauth2/access_token", json: { access_token: "user-token" } },
      {
        match: "api.foursquare.com/v2/users/self",
        json: { meta: { code: 200 }, response: { user: { id: "12345" } } },
      },
    ]);
    startSwarmImport.mockResolvedValue(importRow());
    const state = await createOAuthStateToken(CURRENT_USER_ID, "foursquare");

    const response = await callback({ code: "auth-code", state });

    expect(response.status).toBe(302);
    expect(response.headers.get("Location")).toBe("hackysack://swarm-import?status=started");
    expect(controls.operations).toEqual(["insert"]);
    expect(startSwarmImport).toHaveBeenCalledWith(CURRENT_USER_ID);
    const exchange = new URL(fetchStub.calls[0]!.url);
    expect(exchange.searchParams.get("code")).toBe("auth-code");
    expect(exchange.searchParams.get("grant_type")).toBe("authorization_code");
  });

  it("refuses a forged state without calling Foursquare", async () => {
    fetchStub = stubFetch([]);

    const response = await callback({ code: "auth-code", state: "forged" });

    expect(response.headers.get("Location")).toBe(
      "hackysack://swarm-import?status=error&reason=expired",
    );
    expect(fetchStub.calls).toHaveLength(0);
    expect(controls.operations).toEqual([]);
  });

  it("refuses an access token passed off as a state", async () => {
    const response = await callback({ code: "auth-code", state: accessToken });

    expect(response.headers.get("Location")).toContain("reason=expired");
  });

  it("returns to the app when the user denies access", async () => {
    const response = await callback({ error: "access_denied" });

    expect(response.headers.get("Location")).toBe(
      "hackysack://swarm-import?status=error&reason=denied",
    );
  });

  it("reports a failed token exchange", async () => {
    fetchStub = stubFetch([
      { match: "foursquare.com/oauth2/access_token", status: 400, json: { error: "invalid_grant" } },
    ]);
    const state = await createOAuthStateToken(CURRENT_USER_ID, "foursquare");

    const response = await callback({ code: "auth-code", state });

    expect(response.headers.get("Location")).toContain("reason=failed");
    expect(startSwarmImport).not.toHaveBeenCalled();
  });
});

describe("GET /", () => {
  it("reports the connection and the latest import", async () => {
    controls.queue([{ connectedAt: new Date() }], [importRow()]);

    const response = await send("GET", "/");

    expect(response.status).toBe(200);
    const body = (await response.json()) as Record<string, unknown>;
    expect(body.connected).toBe(true);
    expect(body.latestImport).toMatchObject({ status: "running", checkinsImported: 250 });
    // Nothing about the token ever leaves the server.
    expect(JSON.stringify(body)).not.toContain("Ciphertext");
  });

  it("reports no connection", async () => {
    controls.queue([], []);

    const response = await send("GET", "/");

    expect(await response.json()).toEqual({ connected: false, latestImport: null });
  });
});

describe("POST /", () => {
  it("refuses to sync without a connection", async () => {
    controls.queue([]);

    const response = await send("POST", "/");

    expect(response.status).toBe(409);
    expect(startSwarmImport).not.toHaveBeenCalled();
  });

  it("refuses while an import is already running", async () => {
    controls.queue([{ userId: CURRENT_USER_ID }]);
    startSwarmImport.mockResolvedValue(null);

    const response = await send("POST", "/");

    expect(response.status).toBe(409);
  });

  it("starts a sync", async () => {
    controls.queue([{ userId: CURRENT_USER_ID }]);
    startSwarmImport.mockResolvedValue(importRow({ checkinsImported: 0 }));

    const response = await send("POST", "/");

    expect(response.status).toBe(202);
  });
});
