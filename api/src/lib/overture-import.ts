/**
 * Writes parsed Overture data into the database. Shared by the file
 * importers (`npm run overture:import`), the coverage worker and the seed
 * script, so every path upserts the same way: on the stable GERS id, only
 * rewriting rows that actually changed, and stamping the release they were
 * last seen in so a refresh can retire what a newer release dropped.
 */

import { and, eq, inArray, isNull, lt, sql } from "drizzle-orm";
import { database } from "../db/index.js";
import { coverageCells, places } from "../db/schema.js";
import type { Bounds, Cell } from "./coverage-cells.js";
import type { OverturePlaceInsert } from "./overture.js";

/**
 * Rows per upsert statement. Each row binds 17 parameters and Postgres
 * allows 65,535 per statement, so this could go to about 3,800; 2,000 keeps
 * a statement comfortably small while making a quarter as many round trips
 * as 500 did.
 */
export const UPSERT_BATCH_SIZE = 2000;

const COMPARED_COLUMNS = [
  "name",
  "primary_type",
  "types",
  "address_street",
  "address_locality",
  "address_region",
  "address_postcode",
  "address_country",
  "latitude",
  "longitude",
  "confidence",
  "website",
  "phone",
] as const;

function excluded(column: string) {
  return sql.raw(`excluded.${column}`);
}

/**
 * True when any compared column differs between the stored row and the
 * incoming one, so `updated_at` moves only on real change and a monthly
 * refresh does not rewrite every row's timestamp.
 */
const rowChanged = sql`(${sql.join(
  COMPARED_COLUMNS.map((column) => sql.raw(`"places"."${column}"`)),
  sql`, `,
)}) is distinct from (${sql.join(
  COMPARED_COLUMNS.map((column) => excluded(column)),
  sql`, `,
)})`;

export interface UpsertOutcome {
  /** Rows inserted or changed. */
  changed: number;
  /** Rows the fetch contained, changed or not. */
  seen: number;
}

/**
 * Upserts one batch of places for `release`. Every row present is stamped
 * with the release (and un-retired); only rows whose content differs get a
 * new `updated_at`. A row that is already identical, stamped with this
 * release and not retired is left alone entirely, so re-importing an area
 * (a city job over the fix cells inside it, a rerun seed) does not rewrite
 * every row and its seven indexes for nothing.
 */
export async function upsertOverturePlaces(
  rows: OverturePlaceInsert[],
  release: string,
): Promise<UpsertOutcome> {
  if (rows.length === 0) {
    return { changed: 0, seen: 0 };
  }
  // Sorted so two jobs whose areas overlap lock shared rows in the same
  // order and cannot deadlock each other.
  const stamped = [...rows]
    .sort((first, second) => (first.overtureId ?? "").localeCompare(second.overtureId ?? ""))
    .map((row) => ({ ...row, lastSeenRelease: release, retiredAt: null }));
  const written = await database
    .insert(places)
    .values(stamped)
    .onConflictDoUpdate({
      target: places.overtureId,
      set: {
        name: excluded("name"),
        primaryType: excluded("primary_type"),
        types: excluded("types"),
        addressStreet: excluded("address_street"),
        addressLocality: excluded("address_locality"),
        addressRegion: excluded("address_region"),
        addressPostcode: excluded("address_postcode"),
        addressCountry: excluded("address_country"),
        latitude: excluded("latitude"),
        longitude: excluded("longitude"),
        confidence: excluded("confidence"),
        website: excluded("website"),
        phone: excluded("phone"),
        lastSeenRelease: excluded("last_seen_release"),
        retiredAt: sql`null`,
        updatedAt: sql`case when ${rowChanged} then now() else ${places.updatedAt} end`,
      },
      setWhere: sql`${rowChanged}
        or ${places.lastSeenRelease} is distinct from ${excluded("last_seen_release")}
        or ${places.retiredAt} is not null`,
    })
    .returning({ changed: sql<boolean>`${places.updatedAt} = now()` });
  // Rows the setWhere skipped are not returned, so `seen` is the input.
  return { changed: written.filter((row) => row.changed).length, seen: rows.length };
}

/**
 * Rows the new release no longer contains: Overture places inside `bounds`
 * that the fetch for `release` did not touch. Retired rather than deleted,
 * because checkins point at them; a later release that brings one back
 * clears `retired_at` through the upsert above.
 */
export async function retirePlacesMissingFrom(bounds: Bounds, release: string): Promise<number> {
  const retired = await database
    .update(places)
    .set({ retiredAt: sql`now()` })
    .where(
      and(
        eq(places.source, "overture"),
        isNull(places.retiredAt),
        lt(places.lastSeenRelease, release),
        // The box overlap uses the geometry index; the half-open ranges
        // then settle the edges, so a place on a shared boundary belongs
        // to exactly one area.
        sql`${places.location} && ST_MakeEnvelope(${bounds.west}, ${bounds.south}, ${bounds.east}, ${bounds.north}, 4326)`,
        sql`${places.longitude} >= ${bounds.west} and ${places.longitude} < ${bounds.east}`,
        sql`${places.latitude} >= ${bounds.south} and ${places.latitude} < ${bounds.north}`,
      ),
    )
    .returning({ id: places.id });
  return retired.length;
}

export async function markCells(
  cells: Cell[],
  status: "pending" | "ready" | "failed",
  release: string | null,
  jobId: string | null,
): Promise<void> {
  const statement = markCellsStatement(cells, status, release, jobId);
  if (statement) {
    await statement;
  }
}

/**
 * The upsert `markCells` runs, unexecuted, so a caller can put it in a
 * `database.batch` with the statement that goes with it. Null when there
 * are no cells to mark.
 */
export function markCellsStatement(
  cells: Cell[],
  status: "pending" | "ready" | "failed",
  release: string | null,
  jobId: string | null,
) {
  if (cells.length === 0) {
    return null;
  }
  return database
    .insert(coverageCells)
    .values(
      cells.map((cell) => ({
        cellX: cell.cellX,
        cellY: cell.cellY,
        status,
        jobId,
        overtureRelease: release,
        readyAt: status === "ready" ? new Date() : null,
      })),
    )
    .onConflictDoUpdate({
      target: [coverageCells.cellX, coverageCells.cellY],
      set: {
        status: sql`excluded.status`,
        jobId: sql`excluded.job_id`,
        overtureRelease: sql`excluded.overture_release`,
        readyAt: sql`excluded.ready_at`,
        updatedAt: sql`now()`,
      },
    });
}

/** The status of each cell, absent for cells nobody has touched. */
export async function cellStatuses(cells: Cell[]): Promise<Map<string, typeof coverageCells.$inferSelect>> {
  if (cells.length === 0) {
    return new Map();
  }
  const rows = await database
    .select()
    .from(coverageCells)
    .where(
      inArray(
        sql`(${coverageCells.cellX}, ${coverageCells.cellY})`,
        cells.map((cell) => sql`(${cell.cellX}, ${cell.cellY})`),
      ),
    );
  return new Map(rows.map((row) => [`${row.cellX}:${row.cellY}`, row]));
}
