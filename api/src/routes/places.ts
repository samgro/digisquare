import { Hono } from "hono";
import { z } from "zod";
import {
  searchAutocomplete,
  searchNearbyCandidates,
  type GooglePlace,
} from "../lib/google-places.js";

const querySchema = z.object({
  lat: z.coerce.number().min(-90).max(90),
  lng: z.coerce.number().min(-180).max(180),
  q: z.string().trim().min(1).optional(),
  radius: z.coerce.number().int().positive().max(50000).default(1500),
  // The phone's horizontal accuracy in meters. Optional because older
  // clients don't send it and Core Location reports a negative value when
  // it has no estimate, which the client maps to "absent".
  accuracy: z.coerce.number().nonnegative().max(100000).optional(),
});

export interface PlaceResult {
  id: string;
  name: string;
  address: string | null;
  location: { latitude: number; longitude: number } | null;
  viewport: {
    low: { latitude: number; longitude: number };
    high: { latitude: number; longitude: number };
  } | null;
  types: string[];
  primaryType: string | null;
  rating: number | null;
  userRatingCount: number | null;
}

export function toResult(place: GooglePlace): PlaceResult {
  return {
    id: place.id,
    name: place.displayName?.text ?? "",
    address: place.formattedAddress ?? null,
    location: place.location
      ? { latitude: place.location.latitude, longitude: place.location.longitude }
      : null,
    viewport: place.viewport
      ? {
          low: { latitude: place.viewport.low.latitude, longitude: place.viewport.low.longitude },
          high: {
            latitude: place.viewport.high.latitude,
            longitude: place.viewport.high.longitude,
          },
        }
      : null,
    types: place.types ?? [],
    primaryType: place.primaryType ?? null,
    rating: place.rating ?? null,
    userRatingCount: place.userRatingCount ?? null,
  };
}

export const places = new Hono();

places.get("/", async (context) => {
  const parsed = querySchema.safeParse(context.req.query());
  if (!parsed.success) {
    return context.json(
      { error: "Invalid query parameters", details: parsed.error.flatten() },
      400,
    );
  }

  const { lat: latitude, lng: longitude, q: query, radius, accuracy } = parsed.data;

  try {
    const googlePlaces = query
      ? await searchAutocomplete({ query, latitude, longitude, radius })
      : await searchNearbyCandidates({ latitude, longitude, radius, accuracy });

    return context.json({ results: googlePlaces.map(toResult) });
  } catch (error) {
    console.error(error);
    return context.json({ error: "Failed to fetch places from Google" }, 502);
  }
});
