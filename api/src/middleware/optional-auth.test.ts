import { Hono } from "hono";
import { describe, expect, it } from "vitest";
import { createAccessToken } from "../lib/tokens.js";
import type { AppEnv } from "../types.js";
import { optionalAuth } from "./optional-auth.js";

const app = new Hono<AppEnv>();
app.get("/whoami", optionalAuth, (context) => context.json({ viewer: context.get("viewerUserId") }));

describe("optionalAuth", () => {
  it("is anonymous without a header", async () => {
    const response = await app.request("/whoami");
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ viewer: null });
  });

  it("identifies a valid token", async () => {
    const token = await createAccessToken("550e8400-e29b-41d4-a716-446655440000", "22222222-2222-2222-2222-222222222222");
    const response = await app.request("/whoami", { headers: { Authorization: `Bearer ${token}` } });
    expect(await response.json()).toEqual({ viewer: "550e8400-e29b-41d4-a716-446655440000" });
  });

  it("refuses a bad or malformed token rather than downgrading to anonymous", async () => {
    expect((await app.request("/whoami", { headers: { Authorization: "Bearer nope" } })).status).toBe(401);
    expect((await app.request("/whoami", { headers: { Authorization: "Basic abc" } })).status).toBe(401);
  });
});
