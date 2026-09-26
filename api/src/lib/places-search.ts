import { and, asc, desc, eq, getTableColumns, isNull, or, sql, type SQL } from "drizzle-orm";
import { database } from "../db/index.js";
import { checkins, places } from "../db/schema.js";
import { friendIdsOf } from "./friendships.js";

type PlaceRow = typeof places.$inferSelect;

/**
 * A `places` row plus what a search adds: how many checkins (from everyone)
 * point at it, its extent as GeoJSON with its bounding box, and its
 * distance from the searched fix.
 */
export interface PlaceCandidate extends Omit<PlaceRow, "location" | "extent"> {
  checkinCount: number;
  /** `ST_AsGeoJSON` of the simplified extent, or null. */
  extentGeoJson: string | null;
  extentSouth: number | null;
  extentWest: number | null;
  extentNorth: number | null;
  extentEast: number | null;
  /** Null when the row was fetched by id rather than around a fix. */
  distanceMeters: number | null;
}

/** How many rows each of the searches returns at most. */
export const SEARCH_RESULT_LIMIT = 20;

/**
 * Above this accuracy the fix is a cell-tower or reduced-accuracy guess, so
 * "nearest to the fix" is noise: only the large venues, which are found by
 * their grounds or their type rather than their pin, are worth listing.
 */
const MAXIMUM_ACCURACY_FOR_DISTANCE_SEARCH = 1000;

/**
 * Overture categories for venues big enough that the user can be inside one
 * while far from its pin. The fallback for venues with no recorded extent;
 * mirrors the large entries in the iOS `PlaceFootprint` table.
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
 * A category search matches on a venue's pin, so the circle has to reach
 * from wherever the user stands inside the venue to that pin. Measured over
 * 599 terminal places at 14 US airports, 2 km covers 99.7% of them.
 */
export const MINIMUM_LARGE_VENUE_SEARCH_RADIUS = 2000;

/**
 * A venue with recorded grounds counts as nearby when the user is inside
 * them or this close to their edge.
 */
export const EXTENT_SEARCH_RADIUS = 500;

/**
 * A typed query is matched at least this far out whatever radius the client
 * asked for: someone searching by name is often looking for a place they are
 * not standing at.
 */
export const MINIMUM_NAME_SEARCH_RADIUS = 50_000;

/** About 5 m at the equator: enough to keep an airport under a few hundred vertices. */
const EXTENT_SIMPLIFY_TOLERANCE_DEGREES = 0.00005;

export interface Circle {
  latitude: number;
  longitude: number;
  radius: number;
}

interface SearchNearbyCandidatesParams extends Circle {
  /** The phone's horizontal accuracy in meters, when it reported one. */
  accuracy?: number;
  viewerUserId: string | null;
}

interface SearchByNameParams extends Circle {
  query: string;
  viewerUserId: string | null;
}

function fixGeography({ latitude, longitude }: { latitude: number; longitude: number }): SQL {
  return sql`ST_SetSRID(ST_MakePoint(${longitude}, ${latitude}), 4326)::geography`;
}

/** Meters from the fix to the venue: its grounds when it has them, else its pin. */
function distanceMetersSql(fix: { latitude: number; longitude: number }): SQL<number> {
  return sql<number>`ST_Distance(coalesce(${places.extent}, ${places.location})::geography, ${fixGeography(fix)})`;
}

// Spelled out with an alias rather than `${checkins.placeId} = ${places.id}`:
// drizzle renders columns unqualified inside a select list, so the latter
// becomes `"place_id" = "id"` and compares against the checkins row's own id.
const checkinCountSql = sql<number>`(select count(*)::int from ${checkins} as place_checkins where place_checkins.place_id = ${places}.id)`;

const extentColumns = {
  extentGeoJson: sql<string | null>`ST_AsGeoJSON(ST_SimplifyPreserveTopology(${places.extent}, ${EXTENT_SIMPLIFY_TOLERANCE_DEGREES}))`,
  extentSouth: sql<number | null>`ST_YMin(${places.extent}::geometry)`,
  extentWest: sql<number | null>`ST_XMin(${places.extent}::geometry)`,
  extentNorth: sql<number | null>`ST_YMax(${places.extent}::geometry)`,
  extentEast: sql<number | null>`ST_XMax(${places.extent}::geometry)`,
};

function candidateColumns(fix: { latitude: number; longitude: number } | null) {
  const { location: _location, extent: _extent, ...plainColumns } = getTableColumns(places);
  return {
    ...plainColumns,
    checkinCount: checkinCountSql,
    ...extentColumns,
    distanceMeters: fix ? distanceMetersSql(fix) : sql<number | null>`null::double precision`,
  };
}

function pgTextArray(values: readonly string[]): SQL {
  return sql`ARRAY[${sql.join(
    values.map((value) => sql`${value}`),
    sql`, `,
  )}]::text[]`;
}

/**
 * Which places a viewer may see: every public one, plus the private venues
 * they created or a friend of theirs created. Anonymous viewers see public
 * places only.
 */
export function isVisiblePlace(viewerUserId: string | null): SQL {
  if (viewerUserId === null) {
    return eq(places.isPrivate, false);
  }
  return or(
    eq(places.isPrivate, false),
    eq(places.createdByUserId, viewerUserId),
    sql`${places.createdByUserId} in ${friendIdsOf(viewerUserId)}`,
  ) as SQL;
}

/** Visible, and still present in the current Overture release. */
function isSearchable(viewerUserId: string | null): SQL {
  return and(isVisiblePlace(viewerUserId), isNull(places.retiredAt)) as SQL;
}

function selectCandidates(
  fix: { latitude: number; longitude: number } | null,
  where: SQL,
  orderBy: SQL[],
  limit: number,
): Promise<PlaceCandidate[]> {
  return database
    .select(candidateColumns(fix))
    .from(places)
    .where(where)
    .orderBy(...orderBy)
    .limit(limit) as unknown as Promise<PlaceCandidate[]>;
}

/**
 * One place by id, if the viewer may see it. Retired places are returned
 * (a checkin's place must always load); callers that create checkins check
 * `retiredAt` themselves.
 */
export function findPlaceById(placeIdentifier: string, viewerUserId: string | null): Promise<PlaceCandidate | undefined> {
  return selectCandidates(
    null,
    and(sql`${places.id} = ${placeIdentifier}`, isVisiblePlace(viewerUserId))!,
    [],
    1,
  ).then((rows) => rows[0]);
}

/** The `limit` places whose pin is nearest the center, within `radius` meters. */
export function searchNearest(circle: Circle, viewerUserId: string | null): Promise<PlaceCandidate[]> {
  return selectCandidates(
    circle,
    and(
      isSearchable(viewerUserId),
      sql`ST_DWithin(${places.location}::geography, ${fixGeography(circle)}, ${circle.radius})`,
    )!,
    [asc(sql`ST_Distance(${places.location}::geography, ${fixGeography(circle)})`)],
    SEARCH_RESULT_LIMIT,
  );
}

export function largeVenueSearchCircle({ latitude, longitude, radius }: Circle): Circle {
  return { latitude, longitude, radius: Math.max(radius, MINIMUM_LARGE_VENUE_SEARCH_RADIUS) };
}

/**
 * Venues whose recorded grounds the user is inside or within 500 m of,
 * nearest grounds first. This is what finds the airport from a gate.
 */
export function searchByExtent(circle: Circle, viewerUserId: string | null): Promise<PlaceCandidate[]> {
  return selectCandidates(
    circle,
    and(
      isSearchable(viewerUserId),
      sql`${places.extent} is not null`,
      sql`ST_DWithin(${places.extent}::geography, ${fixGeography(circle)}, ${EXTENT_SEARCH_RADIUS})`,
    )!,
    [asc(distanceMetersSql(circle)), desc(checkinCountSql)],
    SEARCH_RESULT_LIMIT,
  );
}

/**
 * Large venues by category within at least 2 km, best-known first: the
 * fallback for venues Overture's base theme has no polygon for.
 */
export function searchLargeVenues(circle: Circle, viewerUserId: string | null): Promise<PlaceCandidate[]> {
  const searchCircle = largeVenueSearchCircle(circle);
  return selectCandidates(
    searchCircle,
    and(
      isSearchable(viewerUserId),
      sql`${places.types} && ${pgTextArray(LARGE_VENUE_TYPES)}`,
      sql`ST_DWithin(${places.location}::geography, ${fixGeography(searchCircle)}, ${searchCircle.radius})`,
    )!,
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
 * Combines the searches into one candidate list in the order given,
 * deduplicated by id: nearest pins first, then venues whose grounds hold
 * the user, then large venues by category.
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
 * Candidate venues for a checkin, drawn from three searches: the 20 nearest
 * pins (which is what finds an obscure venue the user is standing in), the
 * venues whose recorded grounds the user is inside or beside, and large
 * venues by category within at least 2 km (for grounds Overture does not
 * have). Distance results come first; the client ranks them properly with
 * the user's accuracy and history, so the order here is only a fallback.
 */
export async function searchNearbyCandidates({
  latitude,
  longitude,
  radius,
  accuracy,
  viewerUserId,
}: SearchNearbyCandidatesParams): Promise<PlaceCandidate[]> {
  const circle = { latitude, longitude, radius };
  const searches: Promise<PlaceCandidate[]>[] = [];
  if (shouldSearchByDistance(accuracy)) {
    searches.push(searchNearest(circle, viewerUserId));
  }
  searches.push(searchByExtent(circle, viewerUserId));
  searches.push(searchLargeVenues(circle, viewerUserId));
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
export function searchByName({ query, latitude, longitude, radius, viewerUserId }: SearchByNameParams): Promise<PlaceCandidate[]> {
  const circle = { latitude, longitude, radius: Math.max(radius, MINIMUM_NAME_SEARCH_RADIUS) };
  const lowered = query.toLowerCase();
  const wordStartPattern = `(^|[^a-z0-9])${escapeRegex(lowered)}`;
  const startsWord = sql`case when lower(${places.name}) ~ ${wordStartPattern} then 0 else 1 end`;
  return selectCandidates(
    circle,
    and(
      isSearchable(viewerUserId),
      sql`ST_DWithin(${places.location}::geography, ${fixGeography(circle)}, ${circle.radius})`,
      sql`lower(${places.name}) like ${`%${escapeLikePattern(lowered)}%`} escape '\\'`,
    )!,
    [asc(startsWord), desc(checkinCountSql), asc(distanceMetersSql(circle))],
    SEARCH_RESULT_LIMIT,
  );
}
