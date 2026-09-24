import { and, asc, desc, getTableColumns, gte, lte, sql, type SQL } from "drizzle-orm";
import { database } from "../db/index.js";
import { checkins, places } from "../db/schema.js";

export type PlaceRow = typeof places.$inferSelect;

/** A `places` row plus how many checkins (from everyone) point at it. */
export interface PlaceCandidate extends PlaceRow {
  checkinCount: number;
}

/** How many rows each of the searches returns at most. */
export const SEARCH_RESULT_LIMIT = 20;

/**
 * Above this accuracy the fix is a cell-tower or reduced-accuracy guess, so
 * "nearest to the fix" is noise: only the large venues, which are found by
 * their type rather than their pin, are worth listing.
 */
const MAXIMUM_ACCURACY_FOR_DISTANCE_SEARCH = 1000;

/**
 * Overture categories for venues big enough that the user can be inside one
 * while far from its pin. Mirrors the large entries in the iOS
 * `PlaceFootprint` table. Searching for them separately matters: the twenty
 * nearest places to someone inside JFK are rental counters and hotels, never
 * the airport itself.
 */
export const LARGE_VENUE_TYPES = [
  "airport",
  "stadium_arena",
  "college_university",
  "amusement_park",
  "zoo",
  "ski_resort",
  "ski_area",
  "golf_course",
  "national_park",
  "state_park",
  "park",
] as const;

/**
 * A nearby search matches on a venue's pin, so the circle has to reach from
 * wherever the user stands inside the venue to that pin. Measured over 599
 * terminal places at 14 US airports, 2 km covers 99.7% of them and every
 * gate at 13 of the airports (O'Hare's Terminal 5 is 2.3 km out); Golden
 * Gate Park's pin is 1.3 km from the de Young.
 */
export const MINIMUM_LARGE_VENUE_SEARCH_RADIUS = 2000;

/**
 * A typed query is matched at least this far out whatever radius the client
 * asked for: someone searching by name is often looking for a place they are
 * not standing at.
 */
export const MINIMUM_NAME_SEARCH_RADIUS = 50_000;

const METERS_PER_DEGREE_LATITUDE = 111_320;
const EARTH_RADIUS_METERS = 6_371_000;

interface Circle {
  latitude: number;
  longitude: number;
  radius: number;
}

interface SearchNearbyCandidatesParams extends Circle {
  /** The phone's horizontal accuracy in meters, when it reported one. */
  accuracy?: number;
}

interface SearchByNameParams extends Circle {
  query: string;
}

/** Great-circle distance in meters from the circle's center to a row's pin. */
function distanceMetersSql({ latitude, longitude }: Circle): SQL<number> {
  return sql<number>`(2 * ${EARTH_RADIUS_METERS} * asin(sqrt(
    pow(sin(radians(${places.latitude} - ${latitude}) / 2), 2)
    + cos(radians(${latitude})) * cos(radians(${places.latitude}))
      * pow(sin(radians(${places.longitude} - ${longitude}) / 2), 2)
  )))`;
}

/**
 * Bounding-box prefilter (which the latitude/longitude index serves) plus
 * the exact distance check. Rows without a pin never match.
 */
function withinCircle(circle: Circle): SQL {
  const latitudeDelta = circle.radius / METERS_PER_DEGREE_LATITUDE;
  // Near the poles a degree of longitude shrinks towards nothing; the floor
  // keeps the box finite there rather than dividing by zero.
  const metersPerDegreeLongitude =
    METERS_PER_DEGREE_LATITUDE * Math.max(Math.cos((circle.latitude * Math.PI) / 180), 0.01);
  const longitudeDelta = circle.radius / metersPerDegreeLongitude;
  return and(
    gte(places.latitude, circle.latitude - latitudeDelta),
    lte(places.latitude, circle.latitude + latitudeDelta),
    gte(places.longitude, circle.longitude - longitudeDelta),
    lte(places.longitude, circle.longitude + longitudeDelta),
    lte(distanceMetersSql(circle), circle.radius),
  )!;
}

// Spelled out with an alias rather than `${checkins.placeId} = ${places.id}`:
// drizzle renders columns unqualified inside a select list, so the latter
// becomes `"place_id" = "id"` and compares against the checkins row's own id.
const checkinCountSql = sql<number>`(select count(*)::int from ${checkins} as place_checkins where place_checkins.place_id = ${places}.id)`;

function pgTextArray(values: readonly string[]): SQL {
  return sql`ARRAY[${sql.join(
    values.map((value) => sql`${value}`),
    sql`, `,
  )}]::text[]`;
}

function selectCandidates(where: SQL, orderBy: SQL[], limit: number): Promise<PlaceCandidate[]> {
  return database
    .select({ ...getTableColumns(places), checkinCount: checkinCountSql })
    .from(places)
    .where(where)
    .orderBy(...orderBy)
    .limit(limit);
}

/** Everyone who can see the picker, so no user filter. */
export function findPlaceById(placeIdentifier: string): Promise<PlaceCandidate | undefined> {
  return selectCandidates(sql`${places.id} = ${placeIdentifier}`, [], 1).then((rows) => rows[0]);
}

/** The `limit` places nearest the center, within `radius` meters. */
export function searchNearest(circle: Circle): Promise<PlaceCandidate[]> {
  return selectCandidates(withinCircle(circle), [asc(distanceMetersSql(circle))], SEARCH_RESULT_LIMIT);
}

export function largeVenueSearchCircle({ latitude, longitude, radius }: Circle): Circle {
  return { latitude, longitude, radius: Math.max(radius, MINIMUM_LARGE_VENUE_SEARCH_RADIUS) };
}

/**
 * Large venues within at least 2 km, best-known first: the ones people
 * check in at most, then the nearest.
 */
export function searchLargeVenues(circle: Circle): Promise<PlaceCandidate[]> {
  const searchCircle = largeVenueSearchCircle(circle);
  return selectCandidates(
    and(withinCircle(searchCircle), sql`${places.types} && ${pgTextArray(LARGE_VENUE_TYPES)}`)!,
    [desc(checkinCountSql), asc(distanceMetersSql(searchCircle))],
    SEARCH_RESULT_LIMIT,
  );
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
 * first, then large venues that were not already nearest, deduplicated by id.
 */
export function mergeNearbyResults(resultLists: PlaceCandidate[][]): PlaceCandidate[] {
  const merged: PlaceCandidate[] = [];
  const seenIdentifiers = new Set<string>();
  for (const candidates of resultLists) {
    for (const candidate of candidates) {
      if (seenIdentifiers.has(candidate.id)) {
        continue;
      }
      seenIdentifiers.add(candidate.id);
      merged.push(candidate);
    }
  }
  return merged;
}

/**
 * Candidate venues for a checkin, drawn from two searches: the 20 nearest
 * places (which is what finds an obscure venue the user is standing in) and
 * the 20 best-known large venues within at least 2 km (which is what finds an
 * airport, stadium or park whose pin is far from where the user stands).
 * Distance results come first; the client ranks them properly with the user's
 * accuracy and history, so the order here is only a fallback.
 */
export async function searchNearbyCandidates({
  latitude,
  longitude,
  radius,
  accuracy,
}: SearchNearbyCandidatesParams): Promise<PlaceCandidate[]> {
  const circle = { latitude, longitude, radius };
  const searches: Promise<PlaceCandidate[]>[] = [];
  if (shouldSearchByDistance(accuracy)) {
    searches.push(searchNearest(circle));
  }
  searches.push(searchLargeVenues(circle));
  return mergeNearbyResults(await Promise.all(searches));
}

/** Makes `query` safe inside a LIKE pattern, so "100%" matches literally. */
function escapeLikePattern(query: string): string {
  return query.replace(/[\\%_]/g, (character) => `\\${character}`);
}

function escapeRegex(query: string): string {
  return query.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

/**
 * Substring name search around a location, at least 50 km out. Matches that
 * start a word come first ("cos" finds Costco before "Tacos"), then the
 * places people have checked in at most, then the nearest. Case-insensitive
 * through `lower(name)`, which is what the trigram index is built on.
 */
export function searchByName({ query, latitude, longitude, radius }: SearchByNameParams): Promise<PlaceCandidate[]> {
  const circle = { latitude, longitude, radius: Math.max(radius, MINIMUM_NAME_SEARCH_RADIUS) };
  const lowered = query.toLowerCase();
  const wordStartPattern = `(^|[^a-z0-9])${escapeRegex(lowered)}`;
  const startsWord = sql`case when lower(${places.name}) ~ ${wordStartPattern} then 0 else 1 end`;
  return selectCandidates(
    and(
      withinCircle(circle),
      sql`lower(${places.name}) like ${`%${escapeLikePattern(lowered)}%`} escape '\\'`,
    )!,
    [asc(startsWord), desc(checkinCountSql), asc(distanceMetersSql(circle))],
    SEARCH_RESULT_LIMIT,
  );
}
