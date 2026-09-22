import { createRemoteJWKSet, jwtVerify } from "jose";
import type { JWTVerifyGetKey } from "jose";
import { config } from "../config.js";

const APPLE_ISSUER = "https://appleid.apple.com";

// Module-level singleton on purpose: it caches Apple's signing keys and
// applies a refetch cooldown, so a burst of sign-ins does not turn into a
// burst of requests to Apple. Constructing this per call would defeat both.
const appleKeySet = createRemoteJWKSet(new URL("https://appleid.apple.com/auth/keys"), {
  cacheMaxAge: 24 * 60 * 60 * 1000,
  cooldownDuration: 30 * 1000,
});

export interface AppleIdentity {
  /** Apple's stable `sub`. The only thing we ever key an account on. */
  subject: string;
  email: string | null;
  emailVerified: boolean;
  isPrivateEmail: boolean;
  /** The sha256 hex the client passed to Apple, echoed back in the token. */
  nonceHash: string | null;
}

/**
 * Apple sends `email_verified` and `is_private_email` as real booleans in some
 * responses and as the strings "true"/"false" in others. Normalizing through
 * String() covers both; a plain truthiness check would read the string
 * "false" as true.
 */
function asBoolean(value: unknown): boolean {
  return String(value) === "true";
}

/**
 * @param keySet overridden only by tests. jose's Node build fetches a remote
 * key set through node:https rather than global fetch, so it cannot be stubbed
 * the way the rest of the suite stubs outbound calls — the signature check
 * would otherwise be untestable, and every token would be rejected because the
 * fetch failed rather than because the token was bad.
 */
export async function verifyAppleIdentityToken(
  identityToken: string,
  keySet: JWTVerifyGetKey = appleKeySet,
): Promise<AppleIdentity | null> {
  try {
    const { payload } = await jwtVerify(identityToken, keySet, {
      issuer: APPLE_ISSUER,
      // Pinned to our bundle id. Without this an identity token minted for a
      // different app would be accepted here.
      audience: config.APPLE_BUNDLE_IDENTIFIER,
      algorithms: ["RS256"],
      // Freshness on top of exp. Bounds how long a leaked token stays useful.
      maxTokenAge: "10 minutes",
    });

    if (typeof payload.sub !== "string" || payload.sub.length === 0) {
      return null;
    }

    return {
      subject: payload.sub,
      email: typeof payload.email === "string" ? payload.email.toLowerCase() : null,
      emailVerified: asBoolean(payload.email_verified),
      isPrivateEmail: asBoolean(payload.is_private_email),
      nonceHash: typeof payload.nonce === "string" ? payload.nonce : null,
    };
  } catch {
    // Bad signature, wrong issuer or audience, expired, or not a JWT. The
    // caller answers 401 for all of them.
    return null;
  }
}
