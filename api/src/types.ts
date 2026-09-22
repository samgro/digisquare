/**
 * Values set on the Hono context by middleware.
 *
 * Every router — including the root app in index.ts — must be declared as
 * `new Hono<AppEnv>()`. Hono only propagates the environment generic through
 * `app.route()` when the parent declares it too; without that,
 * `context.get("userId")` types as `unknown`.
 */
export type AppVariables = {
  userId: string;
  sessionId: string;
};

export type AppEnv = { Variables: AppVariables };
