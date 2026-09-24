import { createHash } from "node:crypto";
import { lt, sql } from "drizzle-orm";
import type { Context } from "hono";
import { database } from "../db/index.js";
import { authRateLimits } from "../db/schema.js";

export interface RateLimitRule {
  readonly windowSeconds: number;
  readonly maxAttempts: number;
}

export const RATE_LIMIT_RULES = {
  appleByIpAddress: { windowSeconds: 900, maxAttempts: 30 },
  refreshByIpAddress: { windowSeconds: 900, maxAttempts: 60 },
} as const satisfies Record<string, RateLimitRule>;

export interface RateLimitResult {
  allowed: boolean;
  retryAfterSeconds: number;
}

/**
 * Fixed-window counter, incremented with a single atomic upsert so concurrent
 * requests cannot race past the limit.
 *
 * The identifier is hashed before it becomes part of the key so that IP
 * addresses are not stored in plaintext in a table that exists purely for
 * counting.
 */
export async function consumeRateLimit(
  scope: string,
  identifier: string,
  rule: RateLimitRule,
): Promise<RateLimitResult> {
  const windowMilliseconds = rule.windowSeconds * 1000;
  const windowStartedAt = new Date(
    Math.floor(Date.now() / windowMilliseconds) * windowMilliseconds,
  );
  const identifierHash = createHash("sha256")
    .update(identifier.toLowerCase())
    .digest("hex")
    .slice(0, 32);
  const bucketKey = `${scope}:${identifierHash}`;

  try {
    const [row] = await database
      .insert(authRateLimits)
      .values({ bucketKey, windowStartedAt, attemptCount: 1 })
      .onConflictDoUpdate({
        target: authRateLimits.bucketKey,
        set: {
          // Reset the counter when the stored row belongs to an older window,
          // otherwise increment it.
          attemptCount: sql`case when ${authRateLimits.windowStartedAt} = ${windowStartedAt}
                                 then ${authRateLimits.attemptCount} + 1 else 1 end`,
          windowStartedAt: sql`excluded.window_started_at`,
        },
      })
      .returning({ attemptCount: authRateLimits.attemptCount });

    const attemptCount = row?.attemptCount ?? 1;
    const windowEndsAt = windowStartedAt.getTime() + windowMilliseconds;
    const retryAfterSeconds = Math.max(
      1,
      Math.ceil((windowEndsAt - Date.now()) / 1000),
    );

    return { allowed: attemptCount <= rule.maxAttempts, retryAfterSeconds };
  } catch (error) {
    // Fail open. A rate limiter that takes the whole sign-in flow down with it
    // when the database hiccups is worse than one that misses a window.
    console.error("Rate limit check failed:", error);
    return { allowed: true, retryAfterSeconds: 0 };
  }
}

/**
 * Best-effort cleanup of windows nobody will read again. Called with a low
 * probability from the auth handlers rather than on a schedule, because the
 * app has no job runner.
 */
export function pruneRateLimitsOccasionally(): void {
  if (Math.random() > 0.01) {
    return;
  }
  const cutoff = new Date(Date.now() - 24 * 60 * 60 * 1000);
  void database
    .delete(authRateLimits)
    .where(lt(authRateLimits.windowStartedAt, cutoff))
    .catch((error) => console.error("Rate limit prune failed:", error));
}

/**
 * Note this is only as trustworthy as the proxy in front of us: a client can
 * put anything in x-forwarded-for, so the per-IP buckets are noise reduction
 * rather than a hard guarantee.
 */
export function clientIpAddress(context: Context): string {
  const forwardedFor = context.req.header("x-forwarded-for");
  const firstEntry = forwardedFor?.split(",")[0]?.trim();
  return firstEntry && firstEntry.length > 0 ? firstEntry : "unknown";
}
