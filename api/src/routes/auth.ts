import { createHash, randomUUID } from "node:crypto";
import { Hono } from "hono";
import type { Context } from "hono";
import { and, eq, gt, isNull } from "drizzle-orm";
import { z } from "zod";
import { config } from "../config.js";
import { database } from "../db/index.js";
import { sessions as sessionsTable, users as usersTable } from "../db/schema.js";
import {
  RATE_LIMIT_RULES,
  clientIpAddress,
  consumeRateLimit,
  pruneRateLimitsOccasionally,
} from "../lib/rate-limit.js";
import { verifyAppleIdentityToken } from "../lib/apple.js";
import { isUniqueViolation } from "../lib/database-errors.js";
import { buildAuthEnvelope, prepareSession } from "../lib/sessions.js";
import { createAccessToken, hashRefreshToken } from "../lib/tokens.js";
import type { AppEnv } from "../types.js";

/**
 * How long after a rotation we still accept the token that was rotated.
 *
 * Covers the case where the rotation committed but the response never reached
 * the client — a dropped connection, a backgrounded app. Without it, the
 * client's honest retry looks exactly like a replay and burns the family.
 */
const REFRESH_GRACE_MILLISECONDS = 30_000;

const refreshSchema = z.object({
  refreshToken: z.string().trim().min(1).max(200),
});

const logoutSchema = z.object({
  refreshToken: z.string().trim().min(1).max(200),
});

const appleSignInSchema = z.object({
  identityToken: z.string().min(1),
  // The RAW nonce. The server hashes it and compares against the hash Apple
  // echoed into the token.
  nonce: z.string().min(16).max(128),
  // fullName and email below are UNTRUSTED hints from the client, used only
  // to populate a brand-new account's display name. Identity always comes
  // from the verified token's `sub`, and account matching only ever uses the
  // token's own email claim.
  fullName: z
    .object({
      givenName: z.string().trim().min(1).max(60).nullable().optional(),
      familyName: z.string().trim().min(1).max(60).nullable().optional(),
    })
    .nullable()
    .optional(),
  email: z.string().trim().toLowerCase().email().max(254).nullable().optional(),
});

export const auth = new Hono<AppEnv>();

auth.post("/refresh", async (context) => {
  let body: unknown;
  try {
    body = await context.req.json();
  } catch {
    return context.json({ error: "Invalid JSON body" }, 400);
  }

  const parsed = refreshSchema.safeParse(body);
  if (!parsed.success) {
    return context.json({ error: "Invalid refresh request", details: parsed.error.flatten() }, 400);
  }

  const ipLimit = await consumeRateLimit(
    "refresh-ip",
    clientIpAddress(context),
    RATE_LIMIT_RULES.refreshByIpAddress,
  );
  if (!ipLimit.allowed) {
    context.header("Retry-After", String(ipLimit.retryAfterSeconds));
    return context.json(
      { error: "Too many attempts", retryAfterSeconds: ipLimit.retryAfterSeconds },
      429,
    );
  }

  const tokenHash = hashRefreshToken(parsed.data.refreshToken);
  const now = new Date();

  try {
    // One conditional update settles the whole race: of N concurrent callers
    // holding the same token, exactly one sees a row come back. No
    // transaction needed, which matters because neon-http has none.
    const [claimed] = await database
      .update(sessionsTable)
      .set({ rotatedAt: now })
      .where(
        and(
          eq(sessionsTable.refreshTokenHash, tokenHash),
          isNull(sessionsTable.rotatedAt),
          isNull(sessionsTable.revokedAt),
          gt(sessionsTable.expiresAt, now),
        ),
      )
      .returning();

    if (claimed) {
      return context.json(await rotateInto(claimed, context), 200);
    }

    return await diagnoseFailedClaim(tokenHash, now, context);
  } catch (error) {
    if (error instanceof SessionExpiredError) {
      return context.json({ error: "Session expired" }, 401);
    }
    console.error(error);
    return context.json({ error: "Failed to refresh session" }, 500);
  }
});

/** Issues the successor to a session we just claimed. */
async function rotateInto(
  predecessor: typeof sessionsTable.$inferSelect,
  context: Context,
) {
  const familyAgeMilliseconds = Date.now() - predecessor.familyStartedAt.getTime();
  if (familyAgeMilliseconds > config.REFRESH_TOKEN_ABSOLUTE_TTL_DAYS * 86_400_000) {
    await revokeFamily(predecessor.familyId, "family_expired");
    throw new SessionExpiredError();
  }

  const successor = prepareSession(
    predecessor.userId,
    predecessor.familyId,
    predecessor.familyStartedAt,
    context,
  );

  await database.batch([
    database.insert(sessionsTable).values(successor.values),
    database
      .update(sessionsTable)
      .set({ replacedBySessionId: successor.sessionId })
      .where(eq(sessionsTable.id, predecessor.id)),
  ]);

  return {
    accessToken: await createAccessToken(predecessor.userId, successor.sessionId),
    accessTokenExpiresIn: config.ACCESS_TOKEN_TTL_SECONDS,
    refreshToken: successor.refreshToken,
    refreshTokenExpiresAt: successor.refreshTokenExpiresAt,
  };
}

class SessionExpiredError extends Error {}

/**
 * The claim found nothing. Work out whether this is an honest retry, a token
 * that simply expired, or a genuine replay — only the last one is an attack.
 */
async function diagnoseFailedClaim(tokenHash: string, now: Date, context: Context) {
  const [existing] = await database
    .select()
    .from(sessionsTable)
    .where(eq(sessionsTable.refreshTokenHash, tokenHash));

  // Unknown token, or one that expired without ever being used. Neither is a
  // replay, so neither may punish the family — otherwise anyone who learns a
  // user id could sign them out by posting garbage.
  if (!existing || (existing.rotatedAt === null && existing.revokedAt === null)) {
    return context.json({ error: "Invalid refresh token" }, 401);
  }

  const rotatedAgeMilliseconds = existing.rotatedAt
    ? now.getTime() - existing.rotatedAt.getTime()
    : Number.POSITIVE_INFINITY;

  if (
    existing.revokedAt === null &&
    rotatedAgeMilliseconds < REFRESH_GRACE_MILLISECONDS &&
    existing.replacedBySessionId
  ) {
    const [successor] = await database
      .update(sessionsTable)
      .set({ rotatedAt: now })
      .where(
        and(
          eq(sessionsTable.id, existing.replacedBySessionId),
          isNull(sessionsTable.rotatedAt),
          isNull(sessionsTable.revokedAt),
        ),
      )
      .returning();

    if (successor) {
      try {
        return context.json(await rotateInto(successor, context), 200);
      } catch (error) {
        if (error instanceof SessionExpiredError) {
          return context.json({ error: "Session expired" }, 401);
        }
        throw error;
      }
    }
  }

  await revokeFamily(existing.familyId, "reuse_detected");
  console.warn(`Refresh token reuse detected; revoked family ${existing.familyId}`);
  return context.json({ error: "Invalid refresh token" }, 401);
}

async function revokeFamily(familyId: string, reason: string): Promise<void> {
  await database
    .update(sessionsTable)
    .set({ revokedAt: new Date(), revokedReason: reason })
    .where(and(eq(sessionsTable.familyId, familyId), isNull(sessionsTable.revokedAt)));
}

auth.post("/logout", async (context) => {
  let body: unknown;
  try {
    body = await context.req.json();
  } catch {
    return context.json({ error: "Invalid JSON body" }, 400);
  }

  const parsed = logoutSchema.safeParse(body);
  // An unparseable or unknown token still reports success. Signing out is not
  // a place to tell a caller whether a token was real.
  if (!parsed.success) {
    return context.body(null, 204);
  }

  // No Authorization header is required: an expired access token must never
  // stop someone from signing out.
  try {
    const [existing] = await database
      .select({ familyId: sessionsTable.familyId })
      .from(sessionsTable)
      .where(eq(sessionsTable.refreshTokenHash, hashRefreshToken(parsed.data.refreshToken)));

    if (existing) {
      await revokeFamily(existing.familyId, "logout");
    }

    return context.body(null, 204);
  } catch (error) {
    console.error(error);
    return context.json({ error: "Failed to sign out" }, 500);
  }
});

function displayNameFrom(
  fullName: { givenName?: string | null; familyName?: string | null } | null | undefined,
): string | null {
  const parts = [fullName?.givenName, fullName?.familyName].filter(
    (part): part is string => typeof part === "string" && part.length > 0,
  );
  return parts.length > 0 ? parts.join(" ") : null;
}

auth.post("/apple", async (context) => {
  let body: unknown;
  try {
    body = await context.req.json();
  } catch {
    return context.json({ error: "Invalid JSON body" }, 400);
  }

  const parsed = appleSignInSchema.safeParse(body);
  if (!parsed.success) {
    return context.json({ error: "Invalid Apple sign in", details: parsed.error.flatten() }, 400);
  }

  const ipLimit = await consumeRateLimit(
    "apple-ip",
    clientIpAddress(context),
    RATE_LIMIT_RULES.appleByIpAddress,
  );
  if (!ipLimit.allowed) {
    context.header("Retry-After", String(ipLimit.retryAfterSeconds));
    return context.json(
      { error: "Too many attempts", retryAfterSeconds: ipLimit.retryAfterSeconds },
      429,
    );
  }

  pruneRateLimitsOccasionally();

  const identity = await verifyAppleIdentityToken(parsed.data.identityToken);
  if (!identity) {
    return context.json({ error: "Invalid Apple identity token" }, 401);
  }

  // Apple echoes back the hash the client sent, so binding it to the raw
  // nonce we were given proves this token was minted for this sign-in attempt
  // rather than replayed from another one.
  const expectedNonceHash = createHash("sha256").update(parsed.data.nonce).digest("hex");
  if (identity.nonceHash !== expectedNonceHash) {
    return context.json({ error: "Invalid Apple identity token" }, 401);
  }

  try {
    // 1. Known Apple account. The only match we ever make is on `sub`.
    const [existingByAppleId] = await database
      .select()
      .from(usersTable)
      .where(eq(usersTable.appleUserId, identity.subject));

    if (existingByAppleId) {
      const backfill: Partial<typeof usersTable.$inferInsert> = {};
      // Only ever fill blanks. Apple hands us fullName on the first
      // authorization and null forever after, so overwriting here would wipe
      // a name the user has since set.
      if (existingByAppleId.name === null) {
        const name = displayNameFrom(parsed.data.fullName);
        if (name) {
          backfill.name = name;
        }
      }
      if (existingByAppleId.appleEmail === null && identity.email) {
        backfill.appleEmail = identity.email;
      }

      const updated =
        Object.keys(backfill).length > 0
          ? (
              await database
                .update(usersTable)
                .set(backfill)
                .where(eq(usersTable.id, existingByAppleId.id))
                .returning()
            )[0]
          : existingByAppleId;

      const session = prepareSession(existingByAppleId.id, randomUUID(), new Date(), context);
      await database.insert(sessionsTable).values(session.values);

      return context.json(await buildAuthEnvelope(updated ?? existingByAppleId, session), 200);
    }

    // 2/3. New Apple account. Decide what to do with its email, if any.
    let emailForNewAccount: string | null = identity.email;
    let emailConflict = false;

    if (identity.email) {
      const [existingByEmail] = await database
        .select({ id: usersTable.id })
        .from(usersTable)
        .where(eq(usersTable.email, identity.email));

      if (existingByEmail) {
        // 3b. DO NOT LINK, whether or not the existing account is verified.
        //
        // Linking would hand this Apple user whatever account happens to hold
        // that address, which is an account-takeover primitive: an attacker
        // who claims victim@example.com through another sign-in method first
        // would inherit the victim's real Apple sign-in.
        //
        // Refusing outright (409) is just as wrong in the other direction —
        // it would let that same attacker permanently deny Sign in with Apple
        // to the legitimate owner of the address.
        //
        // So: a separate account. The unique email slot stays with the
        // pre-existing row, and Apple's address is parked in apple_email as
        // the record a future account-linking pass will reconcile from.
        emailForNewAccount = null;
        emailConflict = true;
        console.warn(
          `Apple sign-in email collision: sub ${identity.subject} shares ` +
            `${identity.email} with existing user ${existingByEmail.id}; created a separate account`,
        );
      }
    }

    const userId = randomUUID();
    const session = prepareSession(userId, randomUUID(), new Date(), context);

    const [createdUsers] = await database.batch([
      database
        .insert(usersTable)
        .values({
          id: userId,
          email: emailForNewAccount,
          // Only ever written from Apple's own claim.
          emailVerifiedAt:
            emailForNewAccount !== null && identity.emailVerified ? new Date() : null,
          appleUserId: identity.subject,
          appleEmail: identity.email,
          name: displayNameFrom(parsed.data.fullName),
        })
        .returning(),
      database.insert(sessionsTable).values(session.values),
    ]);

    const created = createdUsers[0];
    if (!created) {
      return context.json({ error: "Failed to sign in with Apple" }, 500);
    }

    const envelope = await buildAuthEnvelope(created, session);
    return context.json(emailConflict ? { ...envelope, emailConflict: true } : envelope, 201);
  } catch (error) {
    // Two devices signing in at once can both miss the lookup and both try to
    // insert the same `sub`. The unique index settles it; the loser just
    // reads the winner's row and signs in.
    if (isUniqueViolation(error)) {
      try {
        const [raced] = await database
          .select()
          .from(usersTable)
          .where(eq(usersTable.appleUserId, identity.subject));

        if (raced) {
          const session = prepareSession(raced.id, randomUUID(), new Date(), context);
          await database.insert(sessionsTable).values(session.values);
          return context.json(await buildAuthEnvelope(raced, session), 200);
        }
      } catch (retryError) {
        console.error(retryError);
      }
    }
    console.error(error);
    return context.json({ error: "Failed to sign in with Apple" }, 500);
  }
});
