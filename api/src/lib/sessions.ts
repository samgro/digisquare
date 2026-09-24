import { randomUUID } from "node:crypto";
import type { Context } from "hono";
import { config } from "../config.js";
import { sessions as sessionsTable, users as usersTable } from "../db/schema.js";
import { clientIpAddress } from "./rate-limit.js";
import { createAccessToken, createRefreshToken } from "./tokens.js";
import { toPrivateUserResult } from "./user-result.js";

function refreshTokenExpiresAt(): Date {
  return new Date(Date.now() + config.REFRESH_TOKEN_TTL_DAYS * 86_400_000);
}

export interface PreparedSession {
  sessionId: string;
  values: typeof sessionsTable.$inferInsert;
  refreshToken: string;
  refreshTokenExpiresAt: Date;
}

/**
 * Builds the row for a new session without writing it, so the caller can put
 * the insert in a batch alongside whatever else has to land atomically.
 *
 * The session id is generated here rather than by the database for the same
 * reason: a batched insert cannot feed a generated id to the next statement.
 */
export function prepareSession(
  userId: string,
  familyId: string,
  familyStartedAt: Date,
  context: Context,
): PreparedSession {
  const { token, tokenHash } = createRefreshToken();
  const expiresAt = refreshTokenExpiresAt();
  const sessionId = randomUUID();

  return {
    sessionId,
    values: {
      id: sessionId,
      userId,
      familyId,
      familyStartedAt,
      refreshTokenHash: tokenHash,
      expiresAt,
      userAgent: context.req.header("User-Agent")?.slice(0, 500) ?? null,
      ipAddress: clientIpAddress(context),
    },
    refreshToken: token,
    refreshTokenExpiresAt: expiresAt,
  };
}

export async function buildAuthEnvelope(
  user: typeof usersTable.$inferSelect,
  session: PreparedSession,
) {
  return {
    user: toPrivateUserResult(user),
    accessToken: await createAccessToken(user.id, session.sessionId),
    accessTokenExpiresIn: config.ACCESS_TOKEN_TTL_SECONDS,
    refreshToken: session.refreshToken,
    refreshTokenExpiresAt: session.refreshTokenExpiresAt,
  };
}
