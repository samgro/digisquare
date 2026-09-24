const PLACES_BASE_URL = "https://places.googleapis.com/v1";

const PLACE_FIELDS = [
  "id",
  "displayName",
  "formattedAddress",
  "location",
  "types",
  "primaryType",
  "rating",
  "userRatingCount",
];

// Search responses wrap places in a `places` array, so every path is prefixed.
const SEARCH_FIELD_MASK = PLACE_FIELDS.map((field) => `places.${field}`).join(",");
// Place Details returns a bare place object, so the paths are NOT prefixed.
// Do not reuse SEARCH_FIELD_MASK here -- Google rejects the `places.` prefix
// on this endpoint with a 400.
const DETAILS_FIELD_MASK = PLACE_FIELDS.join(",");
const AUTOCOMPLETE_FIELD_MASK = "suggestions.placePrediction.placeId";

// Google's Autocomplete (New) endpoint caps responses at five suggestions
// total, with no parameter to raise it. This constant documents that intent
// rather than actively limiting anything -- it's a ceiling for if Google
// ever raises the cap, since each detail lookup is a separate billable call.
const MAXIMUM_PREDICTION_DETAIL_LOOKUPS = 5;

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

interface AutocompleteParams {
  query: string;
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

interface AutocompleteSuggestion {
  placePrediction?: { placeId?: string };
}

function apiKey(): string {
  const key = process.env.GOOGLE_PLACES_API_KEY;
  if (!key) {
    throw new Error("GOOGLE_PLACES_API_KEY is not set");
  }
  return key;
}

async function requestGoogle<ResponseBody>(options: {
  path: string;
  method: "GET" | "POST";
  fieldMask: string;
  body?: unknown;
}): Promise<ResponseBody> {
  const response = await fetch(`${PLACES_BASE_URL}/${options.path}`, {
    method: options.method,
    headers: {
      "Content-Type": "application/json",
      "X-Goog-Api-Key": apiKey(),
      "X-Goog-FieldMask": options.fieldMask,
    },
    ...(options.body === undefined ? {} : { body: JSON.stringify(options.body) }),
  });

  if (!response.ok) {
    const responseText = await response.text();
    throw new Error(`Google Places API error (${response.status}): ${responseText}`);
  }

  return (await response.json()) as ResponseBody;
}

async function postPlaces(path: string, body: unknown): Promise<GooglePlace[]> {
  const data = await requestGoogle<{ places?: GooglePlace[] }>({
    path: `places:${path}`,
    method: "POST",
    fieldMask: SEARCH_FIELD_MASK,
    body,
  });
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

/**
 * Whole-token text search, biased toward a point. Used by the test user seed
 * script to find real branches of a chain; the /places route goes through
 * searchAutocomplete instead, because searchText cannot match prefixes.
 */
export function searchText({
  query,
  latitude,
  longitude,
  radius,
}: SearchTextParams): Promise<GooglePlace[]> {
  return postPlaces("searchText", {
    textQuery: query,
    maxResultCount: 5,
    locationBias: {
      circle: {
        center: { latitude, longitude },
        radius,
      },
    },
  });
}

export function fetchPlaceDetails(placeIdentifier: string): Promise<GooglePlace> {
  return requestGoogle<GooglePlace>({
    path: `places/${encodeURIComponent(placeIdentifier)}`,
    method: "GET",
    fieldMask: DETAILS_FIELD_MASK,
  });
}

export async function autocompletePlaceIdentifiers({
  query,
  latitude,
  longitude,
  radius,
}: AutocompleteParams): Promise<string[]> {
  const data = await requestGoogle<{ suggestions?: AutocompleteSuggestion[] }>({
    path: "places:autocomplete",
    method: "POST",
    fieldMask: AUTOCOMPLETE_FIELD_MASK,
    body: {
      input: query,
      locationBias: {
        circle: {
          center: { latitude, longitude },
          radius,
        },
      },
    },
  });

  // Suggestions are a union of placePrediction/queryPrediction. Only place
  // predictions carry a placeId; query predictions (bare search phrases) are
  // dropped since there's no place to fetch details for.
  return (data.suggestions ?? [])
    .map((suggestion) => suggestion.placePrediction?.placeId)
    .filter(
      (placeIdentifier): placeIdentifier is string =>
        typeof placeIdentifier === "string" && placeIdentifier.length > 0,
    );
}

/**
 * Substring/prefix place search. Google's searchText endpoint only matches
 * whole tokens (so "cos" never matches "Costco"), so partial queries are
 * routed through Autocomplete (which does prefix matching) and then resolved
 * to full place details to keep the response shape identical to searchText's.
 */
export async function searchAutocomplete(params: AutocompleteParams): Promise<GooglePlace[]> {
  const placeIdentifiers = (await autocompletePlaceIdentifiers(params)).slice(
    0,
    MAXIMUM_PREDICTION_DETAIL_LOOKUPS,
  );
  if (placeIdentifiers.length === 0) {
    return [];
  }

  const outcomes = await Promise.allSettled(
    placeIdentifiers.map((placeIdentifier) => fetchPlaceDetails(placeIdentifier)),
  );

  // Promise.allSettled resolves positionally aligned with its input, so this
  // preserves Google's relevance ordering even though the lookups ran in
  // parallel and may have resolved out of order.
  const places: GooglePlace[] = [];
  let firstFailure: unknown;
  for (const [index, outcome] of outcomes.entries()) {
    if (outcome.status === "fulfilled") {
      places.push(outcome.value);
      continue;
    }
    firstFailure ??= outcome.reason;
    console.error(`Failed to fetch details for place ${placeIdentifiers[index]}`, outcome.reason);
  }

  // A single stale place ID among several is expected steady state and
  // shouldn't fail the whole search. Every lookup failing means we have no
  // results at all, which is an outage, not an empty search -- surface it as
  // an error rather than a quiet empty list.
  if (places.length === 0) {
    throw firstFailure instanceof Error
      ? firstFailure
      : new Error("Failed to fetch place details");
  }

  return places;
}
