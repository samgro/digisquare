const FIELD_MASK = [
  "places.id",
  "places.displayName",
  "places.formattedAddress",
  "places.location",
  "places.types",
  "places.primaryType",
  "places.rating",
  "places.userRatingCount",
].join(",");

export interface GooglePlace {
  id: string;
  displayName?: { text: string };
  formattedAddress?: string;
  location?: { latitude: number; longitude: number };
  types?: string[];
  primaryType?: string;
  rating?: number;
  userRatingCount?: number;
}

interface SearchNearbyParams {
  latitude: number;
  longitude: number;
  radius: number;
}

interface SearchTextParams {
  query: string;
  latitude: number;
  longitude: number;
  radius: number;
}

function apiKey(): string {
  const key = process.env.GOOGLE_PLACES_API_KEY;
  if (!key) {
    throw new Error("GOOGLE_PLACES_API_KEY is not set");
  }
  return key;
}

async function postPlaces(path: string, body: unknown): Promise<GooglePlace[]> {
  const response = await fetch(`https://places.googleapis.com/v1/places:${path}`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "X-Goog-Api-Key": apiKey(),
      "X-Goog-FieldMask": FIELD_MASK,
    },
    body: JSON.stringify(body),
  });

  if (!response.ok) {
    const responseText = await response.text();
    throw new Error(`Google Places API error (${response.status}): ${responseText}`);
  }

  const data = (await response.json()) as { places?: GooglePlace[] };
  return data.places ?? [];
}

export function searchNearby({
  latitude,
  longitude,
  radius,
}: SearchNearbyParams): Promise<GooglePlace[]> {
  return postPlaces("searchNearby", {
    maxResultCount: 20,
    rankPreference: "POPULARITY",
    locationRestriction: {
      circle: {
        center: { latitude, longitude },
        radius,
      },
    },
  });
}

export function searchText({
  query,
  latitude,
  longitude,
  radius,
}: SearchTextParams): Promise<GooglePlace[]> {
  return postPlaces("searchText", {
    textQuery: query,
    pageSize: 20,
    rankPreference: "DISTANCE",
    locationBias: {
      circle: {
        center: { latitude, longitude },
        radius,
      },
    },
  });
}
