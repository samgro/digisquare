import { Hono } from "hono";
import { and, desc, eq } from "drizzle-orm";
import { z } from "zod";
import { database } from "../db/index.js";
import { checkins as checkinsTable } from "../db/schema.js";
import { requireAuth } from "../middleware/require-auth.js";
import type { AppEnv } from "../types.js";

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
});

const updateCheckinSchema = z
  .object({
    message: z.string().trim().min(1).max(2000).nullable(),
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

function toResult(checkin: typeof checkinsTable.$inferSelect) {
  return {
    id: checkin.id,
    userId: checkin.userId,
    googlePlaceId: checkin.googlePlaceId,
    placeName: checkin.placeName,
    placeAddress: checkin.placeAddress,
    placePrimaryType: checkin.placePrimaryType,
    placeTypes: checkin.placeTypes,
    location:
      checkin.latitude !== null && checkin.longitude !== null
        ? { latitude: checkin.latitude, longitude: checkin.longitude }
        : null,
    message: checkin.message,
    createdAt: checkin.createdAt,
    updatedAt: checkin.updatedAt,
  };
}

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
      })
      .returning();

    return context.json(toResult(created), 201);
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
    userId ? eq(checkinsTable.userId, userId) : undefined,
    googlePlaceId ? eq(checkinsTable.googlePlaceId, googlePlaceId) : undefined,
  ].filter((condition) => condition !== undefined);

  try {
    const rows = await database
      .select()
      .from(checkinsTable)
      .where(conditions.length > 0 ? and(...conditions) : undefined)
      .orderBy(desc(checkinsTable.createdAt))
      .limit(limit)
      .offset(offset);

    return context.json({ results: rows.map(toResult) });
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
      .where(eq(checkinsTable.id, parsed.data.id));

    if (!checkin) {
      return context.json({ error: "Checkin not found" }, 404);
    }

    return context.json(toResult(checkin));
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

    return context.json(toResult(updated));
  } catch (error) {
    console.error(error);
    return context.json({ error: "Failed to update checkin" }, 500);
  }
});
