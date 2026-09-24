import { randomUUID } from "node:crypto";
import { Hono } from "hono";
import { and, asc, eq } from "drizzle-orm";
import { z } from "zod";
import { config } from "../config.js";
import { database } from "../db/index.js";
import { sessions as sessionsTable, users as usersTable } from "../db/schema.js";
import { buildAuthEnvelope, prepareSession } from "../lib/sessions.js";
import { toUserSummary } from "../lib/user-result.js";
import type { AppEnv } from "../types.js";

const sessionParametersSchema = z.object({
  id: z.string().uuid(),
});

/**
 * Dev-only sign in for the iOS debug build's test user picker. None of these
 * routes ask for a credential, so they only exist when ENABLE_TEST_USERS is
 * set, and even then only ever hand out sessions for test users.
 */
export const testUsers = new Hono<AppEnv>();

testUsers.use("*", async (context, next) => {
  if (!config.ENABLE_TEST_USERS) {
    return context.json({ error: "Not found" }, 404);
  }
  await next();
});

testUsers.get("/", async (context) => {
  try {
    const rows = await database
      .select()
      .from(usersTable)
      .where(eq(usersTable.isTestUser, true))
      .orderBy(asc(usersTable.createdAt));

    return context.json({ results: rows.map(toUserSummary) });
  } catch (error) {
    console.error(error);
    return context.json({ error: "Failed to list test users" }, 500);
  }
});

// Creates a test user with no name, so the app sends it through the same
// name setup screen a brand-new Apple account sees.
testUsers.post("/", async (context) => {
  try {
    const userId = randomUUID();
    const session = prepareSession(userId, randomUUID(), new Date(), context);

    const [createdUsers] = await database.batch([
      database.insert(usersTable).values({ id: userId, isTestUser: true }).returning(),
      database.insert(sessionsTable).values(session.values),
    ]);

    const created = createdUsers[0];
    if (!created) {
      return context.json({ error: "Failed to create test user" }, 500);
    }

    return context.json(await buildAuthEnvelope(created, session), 201);
  } catch (error) {
    console.error(error);
    return context.json({ error: "Failed to create test user" }, 500);
  }
});

testUsers.post("/:id/session", async (context) => {
  const parsed = sessionParametersSchema.safeParse(context.req.param());
  if (!parsed.success) {
    return context.json({ error: "Invalid test user id", details: parsed.error.flatten() }, 400);
  }

  try {
    const [user] = await database
      .select()
      .from(usersTable)
      .where(and(eq(usersTable.id, parsed.data.id), eq(usersTable.isTestUser, true)));

    // A real account's id gets the same answer as an unknown one, so this
    // route can never be used to sign in as a real person.
    if (!user) {
      return context.json({ error: "Test user not found" }, 404);
    }

    const session = prepareSession(user.id, randomUUID(), new Date(), context);
    await database.insert(sessionsTable).values(session.values);

    return context.json(await buildAuthEnvelope(user, session), 200);
  } catch (error) {
    console.error(error);
    return context.json({ error: "Failed to sign in as test user" }, 500);
  }
});
