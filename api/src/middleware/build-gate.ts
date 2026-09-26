import { createMiddleware } from "hono/factory";
import { compareBuilds, currentBuildIdentity, formatBuildIdentity, parseBuildIdentity } from "../lib/build-identity.js";
import type { AppEnv } from "../types.js";

/** Every response names the server's build, so the app can spot a switch on any request. */
export const BUILD_HEADER = "X-Hackysack-Build";
/** Sent by Debug simulator builds: the branch and commit the app was built from. */
export const CLIENT_BUILD_HEADER = "X-Hackysack-Client-Build";
/** The `code` in a 409 body, which the app tells apart from other errors. */
export const BUILD_MISMATCH_CODE = "build_mismatch";

/**
 * Refuses a client built from another branch before any route runs, so no
 * session, checkin or coverage job is ever created against the wrong
 * server's database. A client on the same branch but another commit is let
 * through; it shows a banner from the response header instead. Only a
 * server that read its identity from git enforces anything: production
 * never sees the client header, and never refuses.
 */
export const buildGate = createMiddleware<AppEnv>(async (context, next) => {
  const server = await currentBuildIdentity();
  if (server) {
    context.header(BUILD_HEADER, formatBuildIdentity(server));
  }
  const clientHeader = context.req.header(CLIENT_BUILD_HEADER);
  if (server?.source === "git" && clientHeader) {
    const client = parseBuildIdentity(clientHeader);
    if (client && compareBuilds(server, client) === "branch") {
      return context.json(
        {
          error: `This app was built from ${formatBuildIdentity(client)}, but this server is running ${formatBuildIdentity(server)}.`,
          code: BUILD_MISMATCH_CODE,
          server: { branch: server.branch, commit: server.commit },
          client,
        },
        409,
      );
    }
  }
  await next();
});
