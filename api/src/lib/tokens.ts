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
