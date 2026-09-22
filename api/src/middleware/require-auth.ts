import { createMiddleware } from "hono/factory";
import { verifyAccessToken } from "../lib/tokens.js";
import type { AppEnv } from "../types.js";

/**
 * Rejects the request unless it carries a valid access token, and puts the
 * caller's identity on the context for the handler.
 *
 * Verification is signature-only — it never reads the database — so a revoked
 * session keeps working until its access token expires (15 minutes by
 * default). The sessionId claim is already here if instant revocation is ever
 * needed.
 */
export const requireAuth = createMiddleware<AppEnv>(async (context, next) => {
  const authorizationHeader = context.req.header("Authorization");
  if (!authorizationHeader?.startsWith("Bearer ")) {
    context.header("WWW-Authenticate", "Bearer");
    return context.json({ error: "Missing bearer token" }, 401);
  }

  const claims = await verifyAccessToken(authorizationHeader.slice(7).trim());
  if (!claims) {
    context.header("WWW-Authenticate", 'Bearer error="invalid_token"');
    return context.json({ error: "Invalid or expired token" }, 401);
  }

  context.set("userId", claims.userId);
  context.set("sessionId", claims.sessionId);
  await next();
});
