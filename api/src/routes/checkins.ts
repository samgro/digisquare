import { Hono } from "hono";
import { and, desc, eq } from "drizzle-orm";
import { z } from "zod";
import { database } from "../db/index.js";
import { CHECKIN_SOURCES, CHECKIN_VISIBILITIES, checkins as checkinsTable } from "../db/schema.js";
import { toCheckinResult } from "../lib/checkin-result.js";
import { isVisibleCheckin } from "../lib/friendships.js";
import { requireAuth } from "../middleware/require-auth.js";
import type { AppEnv } from "../types.js";

/** How far ahead of the server clock a client-supplied `createdAt` may be. */
const MAXIMUM_CREATED_AT_SKEW_MILLISECONDS = 5 * 60 * 1000;

const createdAtSchema = z
  .string()
  .datetime({ offset: true })
  .transform((value) => new Date(value))
  .refine((date) => date.getTime() <= Date.now() + MAXIMUM_CREATED_AT_SKEW_MILLISECONDS, {
    message: "createdAt must not be in the future",
  });

// No userId here on purpose: identity comes from the access token. The
// schema is left non-strict so an older client still sending one is simply
// ignored rather than rejected with a 400 it cannot act on.
const createCheckinSchema = z.object({
  googlePlaceId: z.string().trim().min(1),
  placeName: z.string().trim().min(1),
  placeAddress: z.string().trim().min(1).nullable().optional(),
  placePrimaryType: z.string().trim().min(1).nullable().optional(),
  placeTypes: z.array(z.string().trim().min(1)).nullable().optional(),
  latitude: z.number().min(-90).max(90).nullable().optional(),
  longitude: z.number().min(-180).max(180).nullable().optional(),
  message: z.string().trim().min(1).max(2000).nullable().optional(),
  visibility: z.enum(CHECKIN_VISIBILITIES).default("public"),
  source: z.enum(CHECKIN_SOURCES).default("manual"),
  // A checkin accepted from a detected visit is backdated to when the visit
  // started, so the timeline shows when the user was there rather than when
  // they tapped Accept.
  createdAt: createdAtSchema.optional(),
});

const updateCheckinSchema = z
  .object({
    message: z.string().trim().min(1).max(2000).nullable(),
    visibility: z.enum(CHECKIN_VISIBILITIES),
  })
  .partial()
  .refine((data) => Object.keys(data).length > 0, {
    message: "At least one field must be provided",
  });

const idParamSchema = z.object({
  id: z.string().uuid(),
});

const listQuerySchema = z.object({
  userId: z.string().uuid().optional(),
  googlePlaceId: z.string().trim().min(1).optional(),
  limit: z.coerce.number().int().positive().max(100).default(20),
  offset: z.coerce.number().int().min(0).default(0),
});

export const checkins = new Hono<AppEnv>();

checkins.use(requireAuth);

checkins.post("/", async (context) => {
  let body: unknown;
  try {
    body = await context.req.json();
  } catch {
    return context.json({ error: "Invalid JSON body" }, 400);
  }

  const parsed = createCheckinSchema.safeParse(body);
  if (!parsed.success) {
    return context.json({ error: "Invalid checkin", details: parsed.error.flatten() }, 400);
  }

  try {
    const [created] = await database
      .insert(checkinsTable)
      .values({
        userId: context.get("userId"),
        googlePlaceId: parsed.data.googlePlaceId,
        placeName: parsed.data.placeName,
        placeAddress: parsed.data.placeAddress ?? null,
        placePrimaryType: parsed.data.placePrimaryType ?? null,
        placeTypes: parsed.data.placeTypes ?? null,
        latitude: parsed.data.latitude ?? null,
        longitude: parsed.data.longitude ?? null,
        message: parsed.data.message ?? null,
        visibility: parsed.data.visibility,
        source: parsed.data.source,
        ...(parsed.data.createdAt === undefined ? {} : { createdAt: parsed.data.createdAt }),
      })
      .returning();

    return context.json(toCheckinResult(created), 201);
  } catch (error) {
    console.error(error);
    return context.json({ error: "Failed to create checkin" }, 500);
  }
});

checkins.get("/", async (context) => {
  const parsed = listQuerySchema.safeParse(context.req.query());
  if (!parsed.success) {
    return context.json(
      { error: "Invalid query parameters", details: parsed.error.flatten() },
      400,
    );
  }

  const { userId, googlePlaceId, limit, offset } = parsed.data;
  const conditions = [
    // Only your own checkins and your friends' public ones. A stranger's
    // userId is filtered to an empty list rather than refused, so the response
    // does not confirm the user exists.
    isVisibleCheckin(context.get("userId")),
    userId ? eq(checkinsTable.userId, userId) : undefined,
    googlePlaceId ? eq(checkinsTable.googlePlaceId, googlePlaceId) : undefined,
  ].filter((condition) => condition !== undefined);

  try {
    const rows = await database
      .select()
      .from(checkinsTable)
      .where(and(...conditions))
      .orderBy(desc(checkinsTable.createdAt))
      .limit(limit)
      .offset(offset);

    return context.json({ results: rows.map(toCheckinResult) });
  } catch (error) {
    console.error(error);
    return context.json({ error: "Failed to fetch checkins" }, 500);
  }
});

checkins.get("/:id", async (context) => {
  const parsed = idParamSchema.safeParse({ id: context.req.param("id") });
  if (!parsed.success) {
    return context.json({ error: "Invalid checkin id" }, 400);
  }

  try {
    const [checkin] = await database
      .select()
      .from(checkinsTable)
      .where(and(eq(checkinsTable.id, parsed.data.id), isVisibleCheckin(context.get("userId"))));

    // A stranger's checkin is the same 404 as one that does not exist.
    if (!checkin) {
      return context.json({ error: "Checkin not found" }, 404);
    }

    return context.json(toCheckinResult(checkin));
  } catch (error) {
    console.error(error);
    return context.json({ error: "Failed to fetch checkin" }, 500);
  }
});

checkins.patch("/:id", async (context) => {
  const paramsParsed = idParamSchema.safeParse({ id: context.req.param("id") });
  if (!paramsParsed.success) {
    return context.json({ error: "Invalid checkin id" }, 400);
  }

  let body: unknown;
  try {
    body = await context.req.json();
  } catch {
    return context.json({ error: "Invalid JSON body" }, 400);
  }

  const bodyParsed = updateCheckinSchema.safeParse(body);
  if (!bodyParsed.success) {
    return context.json(
      { error: "Invalid checkin update", details: bodyParsed.error.flatten() },
      400,
    );
  }

  try {
    // Scoping the update by owner means a checkin that exists but belongs to
    // someone else falls through to the same 404 as one that does not exist.
    // A 403 would confirm the id is real.
    const [updated] = await database
      .update(checkinsTable)
      .set(bodyParsed.data)
      .where(
        and(
          eq(checkinsTable.id, paramsParsed.data.id),
          eq(checkinsTable.userId, context.get("userId")),
        ),
      )
      .returning();

    if (!updated) {
      return context.json({ error: "Checkin not found" }, 404);
    }

    return context.json(toCheckinResult(updated));
  } catch (error) {
    console.error(error);
    return context.json({ error: "Failed to update checkin" }, 500);
  }
});
