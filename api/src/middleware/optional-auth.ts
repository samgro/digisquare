import { createMiddleware } from "hono/factory";
import { verifyAccessToken } from "../lib/tokens.js";
import type { AppEnv } from "../types.js";

/**
 * For routes anyone may call but that show more to a signed-in user (place
 * searches, which include the caller's private venues). No Authorization
 * header means anonymous. A header that is present but bad is refused with
 * a 401 rather than treated as anonymous, so a client holding a stale token
 * refreshes it instead of silently losing its private venues.
 */
export const optionalAuth = createMiddleware<AppEnv>(async (context, next) => {
  const authorizationHeader = context.req.header("Authorization");
  if (!authorizationHeader) {
    context.set("viewerUserId", null);
    await next();
    return;
  }
  if (!authorizationHeader.startsWith("Bearer ")) {
    context.header("WWW-Authenticate", "Bearer");
    return context.json({ error: "Malformed Authorization header" }, 401);
  }
  const claims = await verifyAccessToken(authorizationHeader.slice(7).trim());
  if (!claims) {
    context.header("WWW-Authenticate", 'Bearer error="invalid_token"');
    return context.json({ error: "Invalid or expired token" }, 401);
  }
  context.set("viewerUserId", claims.userId);
  await next();
});
