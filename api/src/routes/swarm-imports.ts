import { Hono } from "hono";
import { desc, eq } from "drizzle-orm";
import { swarmImportConfig } from "../config.js";
import { database } from "../db/index.js";
import {
  foursquareConnections as foursquareConnectionsTable,
  swarmImports as swarmImportsTable,
} from "../db/schema.js";
import { authorizationUrl, exchangeCode, fetchSelf } from "../lib/foursquare.js";
import { startSwarmImport } from "../lib/swarm-import.js";
import { encryptToken } from "../lib/token-encryption.js";
import { createOAuthStateToken, verifyOAuthStateToken } from "../lib/tokens.js";
import { requireAuth } from "../middleware/require-auth.js";
import type { AppEnv } from "../types.js";

const OAUTH_PROVIDER = "foursquare";

// Where the callback sends the browser when it is done. The app opens the
// flow in ASWebAuthenticationSession listening for this scheme, which closes
// the sheet and hands the URL back.
const APP_CALLBACK_URL = "hackysack://swarm-import";

type SwarmImportRow = typeof swarmImportsTable.$inferSelect;

function toSwarmImportResult(swarmImport: SwarmImportRow) {
  return {
    id: swarmImport.id,
    status: swarmImport.status,
    phase: swarmImport.phase,
    checkinsImported: swarmImport.checkinsImported,
    checkinsExpected: swarmImport.checkinsExpected,
    photosTotal: swarmImport.photosTotal,
    photosCopied: swarmImport.photosCopied,
    error: swarmImport.error,
    startedAt: swarmImport.startedAt,
    finishedAt: swarmImport.finishedAt,
  };
}

function appRedirect(status: "started" | "error", reason?: string): string {
  const url = new URL(APP_CALLBACK_URL);
  url.searchParams.set("status", status);
  if (reason) {
    url.searchParams.set("reason", reason);
  }
  return url.toString();
}

export const swarmImports = new Hono<AppEnv>();

// Every route but the OAuth callback requires auth. The callback arrives from
// Foursquare's redirect with no bearer token; the signed state is what
// identifies the user there.
swarmImports.use(async (context, next) => {
  if (context.req.path.endsWith("/callback")) {
    return next();
  }
  return requireAuth(context, next);
});

swarmImports.use(async (context, next) => {
  if (!swarmImportConfig()) {
    return context.json({ error: "Swarm import is not configured" }, 503);
  }
  return next();
});

swarmImports.post("/authorization", async (context) => {
  const configuration = swarmImportConfig()!;
  const state = await createOAuthStateToken(context.get("userId"), OAUTH_PROVIDER);
  return context.json({
    authorizationUrl: authorizationUrl({
      clientId: configuration.clientId,
      redirectUrl: configuration.redirectUrl,
      state,
    }),
  });
});

swarmImports.get("/callback", async (context) => {
  const configuration = swarmImportConfig()!;
  const { code, state, error } = context.req.query();

  // The user tapped Deny, or Foursquare refused for its own reasons.
  if (error || !code) {
    return context.redirect(appRedirect("error", "denied"));
  }

  const userId = state ? await verifyOAuthStateToken(state, OAUTH_PROVIDER) : null;
  if (!userId) {
    return context.redirect(appRedirect("error", "expired"));
  }

  try {
    const accessToken = await exchangeCode({
      clientId: configuration.clientId,
      clientSecret: configuration.clientSecret,
      redirectUrl: configuration.redirectUrl,
      code,
    });
    const { id: foursquareUserId } = await fetchSelf(accessToken);
    const accessTokenCiphertext = encryptToken(accessToken, configuration.tokenEncryptionKey);

    await database
      .insert(foursquareConnectionsTable)
      .values({ userId, foursquareUserId, accessTokenCiphertext })
      .onConflictDoUpdate({
        target: foursquareConnectionsTable.userId,
        set: { foursquareUserId, accessTokenCiphertext, connectedAt: new Date() },
      });

    // Null when an import is already running, which is just as good here.
    await startSwarmImport(userId);
    return context.redirect(appRedirect("started"));
  } catch (callbackError) {
    console.error(callbackError);
    return context.redirect(appRedirect("error", "failed"));
  }
});

swarmImports.get("/", async (context) => {
  const userId = context.get("userId");
  try {
    const [connection] = await database
      .select({ connectedAt: foursquareConnectionsTable.connectedAt })
      .from(foursquareConnectionsTable)
      .where(eq(foursquareConnectionsTable.userId, userId));
    const [latestImport] = await database
      .select()
      .from(swarmImportsTable)
      .where(eq(swarmImportsTable.userId, userId))
      .orderBy(desc(swarmImportsTable.startedAt))
      .limit(1);

    return context.json({
      connected: connection !== undefined,
      latestImport: latestImport ? toSwarmImportResult(latestImport) : null,
    });
  } catch (error) {
    console.error(error);
    return context.json({ error: "Failed to fetch Swarm import" }, 500);
  }
});

// Sync again with the stored connection.
swarmImports.post("/", async (context) => {
  const userId = context.get("userId");
  try {
    const [connection] = await database
      .select({ userId: foursquareConnectionsTable.userId })
      .from(foursquareConnectionsTable)
      .where(eq(foursquareConnectionsTable.userId, userId));
    if (!connection) {
      return context.json({ error: "Swarm is not connected" }, 409);
    }

    const started = await startSwarmImport(userId);
    if (!started) {
      return context.json({ error: "An import is already running" }, 409);
    }
    return context.json(toSwarmImportResult(started), 202);
  } catch (error) {
    console.error(error);
    return context.json({ error: "Failed to start Swarm import" }, 500);
  }
});

// Forgets the Foursquare token. Checkins already imported stay.
swarmImports.delete("/connection", async (context) => {
  try {
    await database
      .delete(foursquareConnectionsTable)
      .where(eq(foursquareConnectionsTable.userId, context.get("userId")));
    return context.body(null, 204);
  } catch (error) {
    console.error(error);
    return context.json({ error: "Failed to disconnect Swarm" }, 500);
  }
});
