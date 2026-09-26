import { Hono } from "hono";
import { z } from "zod";
import { database } from "../db/index.js";
import { places as placesTable } from "../db/schema.js";
import { describeCoverage, type CoverageReport } from "../lib/coverage.js";
import { toPlaceResult } from "../lib/place-result.js";
import { findPlaceById, searchByName, searchNearbyCandidates } from "../lib/places-search.js";
import { optionalAuth } from "../middleware/optional-auth.js";
import { requireAuth } from "../middleware/require-auth.js";
import type { AppEnv } from "../types.js";

const querySchema = z.object({
  lat: z.coerce.number().min(-90).max(90),
  lng: z.coerce.number().min(-180).max(180),
  q: z.string().trim().min(1).max(200).optional(),
  radius: z.coerce.number().int().positive().max(50000).default(1500),
  // The phone's horizontal accuracy in meters. Optional because older
  // clients don't send it and Core Location reports a negative value when
  // it has no estimate, which the client maps to "absent".
  accuracy: z.coerce.number().nonnegative().max(100000).optional(),
  // `passive=1`: report coverage but never start a fetch. For lookups nobody
  // is waiting on, like the app's background visit detection.
  passive: z.enum(["1", "true"]).optional(),
});

const idParamSchema = z.object({
  id: z.string().uuid(),
});

/** Overture's category code shape: lower-case words joined by underscores. */
const categoryCodeSchema = z
  .string()
  .trim()
  .regex(/^[a-z0-9]+(_[a-z0-9]+)*$/, "Must be a category code such as coffee_shop");

const optionalText = (maximumLength: number) =>
  z.string().trim().min(1).max(maximumLength).nullable().optional();

/**
 * A venue the user is adding by hand. The pin is mandatory: a place with no
 * coordinate could never be found by a nearby search, only by name. Private
 * unless the user says otherwise, so a home or an office is not published
 * to strangers by default.
 */
const createPlaceSchema = z.object({
  name: z.string().trim().min(1).max(200),
  primaryType: categoryCodeSchema.nullable().optional(),
  types: z.array(categoryCodeSchema).max(10).optional(),
  street: optionalText(200),
  locality: optionalText(100),
  region: optionalText(100),
  postcode: optionalText(20),
  // ISO 3166-1 alpha-2, as Overture stores it.
  country: z
    .string()
    .trim()
    .regex(/^[A-Za-z]{2}$/, "Must be a two-letter country code")
    .transform((code) => code.toUpperCase())
    .nullable()
    .optional(),
  latitude: z.number().min(-90).max(90),
  longitude: z.number().min(-180).max(180),
  website: z.string().trim().url().max(500).nullable().optional(),
  phone: optionalText(40),
  isPrivate: z.boolean().default(true),
});

export const places = new Hono<AppEnv>();

// Open to anonymous callers; a signed-in one also sees their private venues
// and may trigger a fetch of an uncovered area.
places.get("/", optionalAuth, async (context) => {
  const parsed = querySchema.safeParse(context.req.query());
  if (!parsed.success) {
    return context.json(
      { error: "Invalid query parameters", details: parsed.error.flatten() },
      400,
    );
  }

  const { lat: latitude, lng: longitude, q: query, radius, accuracy } = parsed.data;
  const viewerUserId = context.get("viewerUserId");

  try {
    const [candidates, coverage] = await Promise.all([
      query
        ? searchByName({ query, latitude, longitude, radius, viewerUserId })
        : searchNearbyCandidates({ latitude, longitude, radius, accuracy, viewerUserId }),
      describeCoverage({ latitude, longitude, viewerUserId, passive: parsed.data.passive !== undefined }),
    ]);

    return context.json({ results: candidates.map(toPlaceResult), coverage } satisfies {
      results: unknown[];
      coverage: CoverageReport;
    });
  } catch (error) {
    console.error(error);
    return context.json({ error: "Failed to search places" }, 500);
  }
});

places.get("/:id", optionalAuth, async (context) => {
  const parsed = idParamSchema.safeParse({ id: context.req.param("id") });
  if (!parsed.success) {
    return context.json({ error: "Invalid place id" }, 400);
  }

  try {
    const place = await findPlaceById(parsed.data.id, context.get("viewerUserId"));
    if (!place) {
      return context.json({ error: "Place not found" }, 404);
    }
    return context.json(toPlaceResult(place));
  } catch (error) {
    console.error(error);
    return context.json({ error: "Failed to fetch place" }, 500);
  }
});

places.post("/", requireAuth, async (context) => {
  let body: unknown;
  try {
    body = await context.req.json();
  } catch {
    return context.json({ error: "Invalid JSON body" }, 400);
  }

  const parsed = createPlaceSchema.safeParse(body);
  if (!parsed.success) {
    return context.json({ error: "Invalid place", details: parsed.error.flatten() }, 400);
  }

  const draft = parsed.data;
  // The primary category leads the list; alternates follow without repeats.
  const types = [draft.primaryType ?? null, ...(draft.types ?? [])].filter(
    (type, index, all): type is string => type !== null && all.indexOf(type) === index,
  );

  try {
    const [created] = await database
      .insert(placesTable)
      .values({
        source: "user",
        name: draft.name,
        primaryType: draft.primaryType ?? null,
        types,
        addressStreet: draft.street ?? null,
        addressLocality: draft.locality ?? null,
        addressRegion: draft.region ?? null,
        addressPostcode: draft.postcode ?? null,
        addressCountry: draft.country ?? null,
        latitude: draft.latitude,
        longitude: draft.longitude,
        website: draft.website ?? null,
        phone: draft.phone ?? null,
        isPrivate: draft.isPrivate,
        createdByUserId: context.get("userId"),
      })
      .returning();

    return context.json(
      toPlaceResult({
        ...created,
        checkinCount: 0,
        extentGeoJson: null,
        extentSouth: null,
        extentWest: null,
        extentNorth: null,
        extentEast: null,
        distanceMeters: null,
      }),
      201,
    );
  } catch (error) {
    console.error(error);
    return context.json({ error: "Failed to create place" }, 500);
  }
});
