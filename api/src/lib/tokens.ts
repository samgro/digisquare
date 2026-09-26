import { createHash, randomBytes } from "node:crypto";
import { SignJWT, jwtVerify } from "jose";
import { config } from "../config.js";

const ACCESS_TOKEN_ISSUER = "hackysack-api";
const ACCESS_TOKEN_AUDIENCE = "hackysack-ios";

const signingKey = new TextEncoder().encode(config.AUTH_JWT_SECRET);

export interface AccessTokenClaims {
  userId: string;
  sessionId: string;
}

export async function createAccessToken(
  userId: string,
  sessionId: string,
): Promise<string> {
  return new SignJWT({ sessionId })
    .setProtectedHeader({ alg: "HS256" })
    .setSubject(userId)
    .setIssuer(ACCESS_TOKEN_ISSUER)
    .setAudience(ACCESS_TOKEN_AUDIENCE)
    .setIssuedAt()
    .setExpirationTime(`${config.ACCESS_TOKEN_TTL_SECONDS}s`)
    .sign(signingKey);
}

export async function verifyAccessToken(
  token: string,
): Promise<AccessTokenClaims | null> {
  try {
    const { payload } = await jwtVerify(token, signingKey, {
      // Pinning the algorithm blocks both `alg: none` and the confusion attack
      // where an attacker re-signs with a different family. Never widen this.
      algorithms: ["HS256"],
      issuer: ACCESS_TOKEN_ISSUER,
      audience: ACCESS_TOKEN_AUDIENCE,
    });

    if (typeof payload.sub !== "string" || payload.sub.length === 0) {
      return null;
    }
    if (typeof payload.sessionId !== "string" || payload.sessionId.length === 0) {
      return null;
    }

    return { userId: payload.sub, sessionId: payload.sessionId };
  } catch {
    // Expired, tampered with, or not a JWT at all. The caller answers 401 in
    // every case; distinguishing them only helps an attacker.
    return null;
  }
}

const OAUTH_STATE_AUDIENCE = "hackysack-oauth-state";
const OAUTH_STATE_TTL = "10m";

/**
 * The `state` for a third-party OAuth round trip. The callback arrives from
 * the provider's redirect with no bearer token, so this is the only thing
 * that says which user started the flow. Signing it stops anyone from
 * attaching their own Foursquare account to someone else's Hackysack account,
 * and the provider claim stops a state minted for one provider being replayed
 * against another.
 */
export async function createOAuthStateToken(userId: string, provider: string): Promise<string> {
  return new SignJWT({ provider })
    .setProtectedHeader({ alg: "HS256" })
    .setSubject(userId)
    .setIssuer(ACCESS_TOKEN_ISSUER)
    .setAudience(OAUTH_STATE_AUDIENCE)
    .setIssuedAt()
    .setExpirationTime(OAUTH_STATE_TTL)
    .sign(signingKey);
}

/** The user who started the flow, or null for anything else. */
export async function verifyOAuthStateToken(
  token: string,
  provider: string,
): Promise<string | null> {
  try {
    const { payload } = await jwtVerify(token, signingKey, {
      algorithms: ["HS256"],
      issuer: ACCESS_TOKEN_ISSUER,
      audience: OAUTH_STATE_AUDIENCE,
    });
    if (payload.provider !== provider || typeof payload.sub !== "string" || !payload.sub) {
      return null;
    }
    return payload.sub;
  } catch {
    return null;
  }
}

/**
 * Refresh tokens are opaque, not JWTs: they must be revocable, and a JWT is
 * not. 256 bits of entropy means there is no offline-guessing surface, so a
 * plain SHA-256 is the right store — it also has to be an indexed lookup on
 * every refresh, which a slow password hash could not be.
 */
export function createRefreshToken(): { token: string; tokenHash: string } {
  const token = randomBytes(32).toString("base64url");
  return { token, tokenHash: hashRefreshToken(token) };
}

export function hashRefreshToken(token: string): string {
  return createHash("sha256").update(token).digest("hex");
}
