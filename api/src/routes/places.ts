import { Hono } from "hono";
import { z } from "zod";
import { searchNearby, searchText, type GooglePlace } from "../lib/google-places.js";

const querySchema = z.object({
  lat: z.coerce.number().min(-90).max(90),
  lng: z.coerce.number().min(-180).max(180),
  q: z.string().trim().min(1).optional(),
  radius: z.coerce.number().int().positive().max(50000).default(1500),
});

function toResult(place: GooglePlace) {
  return {
    id: place.id,
    name: place.displayName?.text ?? "",
    address: place.formattedAddress ?? null,
    location: place.location
      ? { latitude: place.location.latitude, longitude: place.location.longitude }
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

  const { lat: latitude, lng: longitude, q: query, radius } = parsed.data;

  try {
    const googlePlaces = query
      ? await searchText({ query, latitude, longitude, radius })
      : await searchNearby({ latitude, longitude, radius });

    return context.json({ results: googlePlaces.map(toResult) });
  } catch (error) {
    console.error(error);
    return context.json({ error: "Failed to fetch places from Google" }, 502);
  }
});
