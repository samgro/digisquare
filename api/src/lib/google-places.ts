const PLACES_BASE_URL = "https://places.googleapis.com/v1";

const PLACE_FIELDS = [
  "id",
  "displayName",
  "formattedAddress",
  "location",
  "viewport",
  "types",
  "primaryType",
  "rating",
  "userRatingCount",
];

// Search responses wrap places in a `places` array, so every path is prefixed.
export const SEARCH_FIELD_MASK = PLACE_FIELDS.map((field) => `places.${field}`).join(",");
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

export interface GoogleLatLng {
  latitude: number;
  longitude: number;
}

export interface GooglePlace {
  id: string;
  displayName?: { text: string };
  formattedAddress?: string;
  location?: GoogleLatLng;
  /**
   * Google's bounding box for the place. Point venues get a default box of a
   * few hundred meters; airports, campuses and parks get their real extent,
   * which is how the client tells a large venue apart from a storefront.
   */
  viewport?: { low: GoogleLatLng; high: GoogleLatLng };
  types?: string[];
  primaryType?: string;
  rating?: number;
  userRatingCount?: number;
}

export type NearbyRankPreference = "DISTANCE" | "POPULARITY";

interface SearchNearbyParams {
  latitude: number;
  longitude: number;
  radius: number;
  rankPreference?: NearbyRankPreference;
  /** Restricts results to places carrying any of these Google types. */
  includedTypes?: readonly string[];
}

interface SearchNearbyCandidatesParams {
  latitude: number;
  longitude: number;
  radius: number;
  /** The phone's horizontal accuracy in meters, when it reported one. */
  accuracy?: number;
}

/**
 * Above this accuracy the fix is a cell-tower or reduced-accuracy guess, so
 * "nearest to the fix" is noise and not worth a billable request.
 */
const MAXIMUM_ACCURACY_FOR_DISTANCE_SEARCH = 1000;

/**
 * Venues big enough that the user can be inside one while far from its pin.
 * Mirrors the large types in the iOS `PlaceFootprint` table. Restricting the
 * search to them matters: an untyped popularity search from inside JFK or
 * SeaTac returns rental counters and hotels, never the airport itself.
 */
export const LARGE_VENUE_TYPES = [
  "airport",
  "stadium",
  "university",
  "amusement_park",
  "zoo",
  "ski_resort",
  "golf_course",
  "national_park",
  "state_park",
  "park",
] as const;

/**
 * Nearby Search matches on a venue's pin, so the circle has to reach from
 * wherever the user stands inside the venue to that pin. Measured over 599
 * terminal places at 14 US airports, 2 km covers 99.7% of them and every
 * gate at 13 of the airports (O'Hare's Terminal 5 is 2.3 km out); Golden
 * Gate Park's pin is 1.3 km from the de Young.
 */
export const MINIMUM_LARGE_VENUE_SEARCH_RADIUS = 2000;

export function largeVenueSearchParams({
  latitude,
  longitude,
  radius,
}: {
  latitude: number;
  longitude: number;
  radius: number;
}): SearchNearbyParams {
  return {
    latitude,
    longitude,
    radius: Math.max(radius, MINIMUM_LARGE_VENUE_SEARCH_RADIUS),
    rankPreference: "POPULARITY",
    includedTypes: LARGE_VENUE_TYPES,
  };
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

export interface PlacesSearchResponse {
  places?: GooglePlace[];
}

/**
 * Raw POST to a `places:*` search endpoint. Exported for the fixture recorder,
 * which stores the untouched response body; everything else should go through
 * the typed wrappers below.
 */
export function postPlacesSearch(path: string, body: unknown): Promise<PlacesSearchResponse> {
  return requestGoogle<PlacesSearchResponse>({
    path: `places:${path}`,
    method: "POST",
    fieldMask: SEARCH_FIELD_MASK,
    body,
  });
}

export function nearbySearchRequestBody({
  latitude,
  longitude,
  radius,
  rankPreference = "POPULARITY",
  includedTypes,
}: SearchNearbyParams) {
  return {
    maxResultCount: 20,
    rankPreference,
    ...(includedTypes ? { includedTypes: [...includedTypes] } : {}),
    locationRestriction: {
      circle: {
        center: { latitude, longitude },
        radius,
      },
    },
  };
}

export async function searchNearby(params: SearchNearbyParams): Promise<GooglePlace[]> {
  const data = await postPlacesSearch("searchNearby", nearbySearchRequestBody(params));
  return data.places ?? [];
}

/**
 * Whether a fix is precise enough for a nearest-first search to mean anything.
 * Above the threshold the fix is a cell-tower or reduced-accuracy guess.
 */
export function shouldSearchByDistance(accuracy: number | undefined): boolean {
  return accuracy === undefined || accuracy <= MAXIMUM_ACCURACY_FOR_DISTANCE_SEARCH;
}

/**
 * Combines the two nearby searches into one candidate list: nearest places
 * first, then large venues that were not already nearest, deduplicated by ID.
 * Pure so the fixture recorder can produce the exact same list from recorded
 * responses that the route produces from live ones.
 */
export function mergeNearbyResults(resultLists: GooglePlace[][]): GooglePlace[] {
  const merged: GooglePlace[] = [];
  const seenIdentifiers = new Set<string>();
  for (const places of resultLists) {
    for (const place of places) {
      if (seenIdentifiers.has(place.id)) {
        continue;
      }
      seenIdentifiers.add(place.id);
      merged.push(place);
    }
  }
  return merged;
}

/**
 * Candidate venues for a checkin, drawn from two Nearby Search calls run in
 * parallel: the 20 nearest places (which is what finds an obscure venue the
 * user is standing in) and the 20 most popular large venues within at least
 * 2 km (which is what finds an airport, stadium or park whose pin is far from
 * where the user stands). Distance results come first; the client ranks them properly
 * with the user's accuracy and history, so the order here is only a fallback.
 *
 * One call failing is tolerated the same way a stale autocomplete place ID is:
 * log it and return the survivor. Only both failing is an outage.
 */
export async function searchNearbyCandidates({
  latitude,
  longitude,
  radius,
  accuracy,
}: SearchNearbyCandidatesParams): Promise<GooglePlace[]> {
  const searches: Promise<GooglePlace[]>[] = [];
  if (shouldSearchByDistance(accuracy)) {
    searches.push(searchNearby({ latitude, longitude, radius, rankPreference: "DISTANCE" }));
  }
  searches.push(searchNearby(largeVenueSearchParams({ latitude, longitude, radius })));

  const outcomes = await Promise.allSettled(searches);

  const resultLists: GooglePlace[][] = [];
  let firstFailure: unknown;
  for (const outcome of outcomes) {
    if (outcome.status === "fulfilled") {
      resultLists.push(outcome.value);
      continue;
    }
    firstFailure ??= outcome.reason;
    console.error("Nearby search failed", outcome.reason);
  }

  if (resultLists.length === 0) {
    throw firstFailure instanceof Error ? firstFailure : new Error("Nearby search failed");
  }

  return mergeNearbyResults(resultLists);
}

/**
 * Whole-token text search, biased toward a point. Used by the test user seed
 * script to find real branches of a chain; the /places route goes through
 * searchAutocomplete instead, because searchText cannot match prefixes.
 */
export async function searchText({
  query,
  latitude,
  longitude,
  radius,
}: SearchTextParams): Promise<GooglePlace[]> {
  const data = await postPlacesSearch("searchText", {
    textQuery: query,
    maxResultCount: 5,
    locationBias: {
      circle: {
        center: { latitude, longitude },
        radius,
      },
    },
  });
  return data.places ?? [];
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
