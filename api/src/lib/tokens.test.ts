import { createHash } from "node:crypto";
import { SignJWT, generateKeyPair } from "jose";
import { describe, expect, it } from "vitest";
import {
  createAccessToken,
  createRefreshToken,
  hashRefreshToken,
  verifyAccessToken,
} from "./tokens.js";

const USER_ID = "550e8400-e29b-41d4-a716-446655440000";
const SESSION_ID = "11111111-2222-3333-4444-555555555555";

const signingKey = () => new TextEncoder().encode(process.env.AUTH_JWT_SECRET!);

describe("access tokens", () => {
  it("round-trips the user and session", async () => {
    const claims = await verifyAccessToken(await createAccessToken(USER_ID, SESSION_ID));
    expect(claims).toEqual({ userId: USER_ID, sessionId: SESSION_ID });
  });

  it("rejects a token that is not a JWT", async () => {
    expect(await verifyAccessToken("not.a.jwt")).toBeNull();
    expect(await verifyAccessToken("")).toBeNull();
  });

  it("rejects a tampered signature", async () => {
    const token = await createAccessToken(USER_ID, SESSION_ID);
    expect(await verifyAccessToken(`${token.slice(0, -3)}AAA`)).toBeNull();
  });

  // The reason verifyAccessToken pins algorithms: ["HS256"]. Without the pin,
  // a token claiming alg:none carries no signature to check and would be
  // accepted, letting anyone mint an identity.
  it("rejects an alg:none forgery", async () => {
    const header = Buffer.from(JSON.stringify({ alg: "none", typ: "JWT" })).toString("base64url");
    const payload = Buffer.from(
      JSON.stringify({
        sub: "attacker",
        sessionId: SESSION_ID,
        iss: "hackysack-api",
        aud: "hackysack-ios",
        exp: Math.floor(Date.now() / 1000) + 600,
      }),
    ).toString("base64url");

    expect(await verifyAccessToken(`${header}.${payload}.`)).toBeNull();
  });

  // The other half of the pin: a token signed with an asymmetric key whose
  // public half an attacker controls must not verify against our secret.
  it("rejects a token signed with a different algorithm", async () => {
    const { privateKey } = await generateKeyPair("RS256");
    const token = await new SignJWT({ sessionId: SESSION_ID })
      .setProtectedHeader({ alg: "RS256" })
      .setSubject(USER_ID)
      .setIssuer("hackysack-api")
      .setAudience("hackysack-ios")
      .setIssuedAt()
      .setExpirationTime("10m")
      .sign(privateKey);

    expect(await verifyAccessToken(token)).toBeNull();
  });

  it("rejects a wrong issuer or audience", async () => {
    const mint = (issuer: string, audience: string) =>
      new SignJWT({ sessionId: SESSION_ID })
        .setProtectedHeader({ alg: "HS256" })
        .setSubject(USER_ID)
        .setIssuer(issuer)
        .setAudience(audience)
        .setIssuedAt()
        .setExpirationTime("10m")
        .sign(signingKey());

    expect(await verifyAccessToken(await mint("someone-else", "hackysack-ios"))).toBeNull();
    expect(await verifyAccessToken(await mint("hackysack-api", "someone-else"))).toBeNull();
  });

  it("rejects an expired token", async () => {
    const token = await new SignJWT({ sessionId: SESSION_ID })
      .setProtectedHeader({ alg: "HS256" })
      .setSubject(USER_ID)
      .setIssuer("hackysack-api")
      .setAudience("hackysack-ios")
      .setIssuedAt(Math.floor(Date.now() / 1000) - 7200)
      .setExpirationTime(Math.floor(Date.now() / 1000) - 3600)
      .sign(signingKey());

    expect(await verifyAccessToken(token)).toBeNull();
  });

  // requireAuth puts whatever comes back on the context, so a token missing
  // either claim must not read as valid.
  it("rejects a token missing the sessionId claim", async () => {
    const token = await new SignJWT({})
      .setProtectedHeader({ alg: "HS256" })
      .setSubject(USER_ID)
      .setIssuer("hackysack-api")
      .setAudience("hackysack-ios")
      .setIssuedAt()
      .setExpirationTime("10m")
      .sign(signingKey());

    expect(await verifyAccessToken(token)).toBeNull();
  });
});

describe("refresh tokens", () => {
  it("issues 256 bits of base64url entropy", () => {
    const { token } = createRefreshToken();
    expect(token).toMatch(/^[A-Za-z0-9_-]{43}$/);
  });

  it("returns the sha256 of the token, never the token itself", () => {
    const { token, tokenHash } = createRefreshToken();
    expect(tokenHash).toBe(createHash("sha256").update(token).digest("hex"));
    expect(tokenHash).not.toContain(token);
  });

  it("hashes deterministically so the stored hash can be looked up", () => {
    const { token, tokenHash } = createRefreshToken();
    expect(hashRefreshToken(token)).toBe(tokenHash);
  });

  it("never repeats a token", () => {
    const tokens = new Set(Array.from({ length: 200 }, () => createRefreshToken().token));
    expect(tokens.size).toBe(200);
  });
});
