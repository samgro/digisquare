/**
 * Reads a release's bridge files once and writes what they say about the
 * venues in the database: how many providers matched each Overture place
 * (`places.provider_count`, the corroboration signal in place-quality.ts),
 * and which Overture place each imported Foursquare venue is
 * (`foursquare_venues.overture_id`, since Foursquare's record ids in the
 * bridge files are the venue ids Swarm checkins carry).
 *
 * The bridge files have no bounding box, so a pass is a scan of the whole
 * release (about 5 GB, minutes on a laptop) however few places are asked
 * about. That is why this is a separate step after seeding or refreshing
 * (`npm run overture:bridge`) rather than part of every coverage job, and
 * why the search adds the bonus when a row is read instead of the import
 * folding it into `prior`: a row a job just rewrote keeps its count.
 */

import { and, asc, eq, gt, isNull, sql } from "drizzle-orm";
import { database } from "../db/index.js";
import { foursquareVenues, places } from "../db/schema.js";
import { fetchBridgeMatches, type OvertureSource } from "./overture-remote.js";

/** Rows per keyset page when listing ids, and per update statement. */
const PAGE_SIZE = 20_000;
const UPDATE_BATCH_SIZE = 1000;

export interface BridgeOutcome {
  /** Overture places in the database. */
  placeCount: number;
  /** Places whose provider count changed. */
  placesUpdated: number;
  /** Foursquare venues in the database. */
  venueCount: number;
  /** Venues whose Overture place was found or changed. */
  venuesMatched: number;
}

/** Every live Overture place's GERS id, in pages so no one query is huge. */
async function listOvertureIds(): Promise<string[]> {
  const ids: string[] = [];
  let after = "";
  for (;;) {
    const page = await database
      .select({ overtureId: places.overtureId })
      .from(places)
      .where(and(eq(places.source, "overture"), isNull(places.retiredAt), gt(places.overtureId, after)))
      .orderBy(asc(places.overtureId))
      .limit(PAGE_SIZE);
    for (const row of page) {
      if (row.overtureId !== null) {
        ids.push(row.overtureId);
      }
    }
    if (page.length < PAGE_SIZE) {
      return ids;
    }
    after = page[page.length - 1]!.overtureId!;
  }
}

async function listFoursquareVenueIds(): Promise<string[]> {
  const rows = await database.select({ id: foursquareVenues.id }).from(foursquareVenues);
  return rows.map((row) => row.id);
}

function chunks<Item>(items: Item[], size: number): Item[][] {
  const out: Item[][] = [];
  for (let start = 0; start < items.length; start += size) {
    out.push(items.slice(start, start + size));
  }
  return out;
}

/** Writes the counts that differ from what is stored; returns how many rows changed. */
export async function writeProviderCounts(providerCounts: Map<string, number>): Promise<number> {
  let updated = 0;
  for (const batch of chunks([...providerCounts], UPDATE_BATCH_SIZE)) {
    const values = sql.join(
      batch.map(([overtureId, count]) => sql`(${overtureId}, ${count}::int)`),
      sql`, `,
    );
    const result = await database.execute(sql`
      update ${places} set provider_count = matched.provider_count
      from (values ${values}) as matched(overture_id, provider_count)
      where ${places.overtureId} = matched.overture_id
        and ${places.providerCount} is distinct from matched.provider_count`);
    updated += result.rowCount ?? 0;
  }
  return updated;
}

/** Points venues at their Overture place where that is new or different; returns how many changed. */
export async function writeVenueMatches(overtureIdsByVenue: Map<string, string>): Promise<number> {
  let updated = 0;
  for (const batch of chunks([...overtureIdsByVenue], UPDATE_BATCH_SIZE)) {
    const values = sql.join(
      batch.map(([venueId, overtureId]) => sql`(${venueId}, ${overtureId})`),
      sql`, `,
    );
    const result = await database.execute(sql`
      update ${foursquareVenues} set overture_id = matched.overture_id
      from (values ${values}) as matched(venue_id, overture_id)
      where ${foursquareVenues.id} = matched.venue_id
        and ${foursquareVenues.overtureId} is distinct from matched.overture_id`);
    updated += result.rowCount ?? 0;
  }
  return updated;
}

/** One pass: read the bridge files for everything in the database and write what changed. */
export async function applyBridgeMatches(
  source: OvertureSource,
  log: (message: string) => void = () => {},
): Promise<BridgeOutcome> {
  const [placeIds, venueIds] = await Promise.all([listOvertureIds(), listFoursquareVenueIds()]);
  log(`${placeIds.length} places and ${venueIds.length} Foursquare venues to look up in release ${source.release}`);
  const matches = await fetchBridgeMatches(source, placeIds, venueIds);
  log(`${matches.providerCounts.size} places and ${matches.overtureIdsByFoursquareRecord.size} venues found in the bridge files`);
  const placesUpdated = await writeProviderCounts(matches.providerCounts);
  const venuesMatched = await writeVenueMatches(matches.overtureIdsByFoursquareRecord);
  return { placeCount: placeIds.length, placesUpdated, venueCount: venueIds.length, venuesMatched };
}
