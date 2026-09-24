import { Hono } from "hono";
import { z } from "zod";
import {
  createOwnCheckin,
  findVisibleCheckin,
  listVisibleCheckins,
  updateOwnCheckin,
} from "../lib/checkin-queries.js";
import { toCheckinResult } from "../lib/checkin-result.js";
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
    const created = await createOwnCheckin(context.get("userId"), {
      googlePlaceId: parsed.data.googlePlaceId,
      placeName: parsed.data.placeName,
      placeAddress: parsed.data.placeAddress ?? null,
      placePrimaryType: parsed.data.placePrimaryType ?? null,
      placeTypes: parsed.data.placeTypes ?? null,
      latitude: parsed.data.latitude ?? null,
      longitude: parsed.data.longitude ?? null,
      message: parsed.data.message ?? null,
    });

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

  try {
    // Only your own checkins and your friends'. A stranger's userId is
    // filtered to an empty list rather than refused, so the response does not
    // confirm the user exists.
    const rows = await listVisibleCheckins(
      context.get("userId"),
      { userId, googlePlaceId },
      { limit, offset },
    );

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
    const checkin = await findVisibleCheckin(context.get("userId"), parsed.data.id);

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
    // Someone else's checkin falls through to the same 404 as a missing one.
    const updated = await updateOwnCheckin(
      context.get("userId"),
      paramsParsed.data.id,
      bodyParsed.data,
    );

    if (!updated) {
      return context.json({ error: "Checkin not found" }, 404);
    }

    return context.json(toCheckinResult(updated));
  } catch (error) {
    console.error(error);
    return context.json({ error: "Failed to update checkin" }, 500);
  }
});
