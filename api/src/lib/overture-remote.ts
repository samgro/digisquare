/**
 * Reads Overture Maps data straight from the public release files with
 * DuckDB, no download step. Each release is GeoParquet on S3 whose files
 * carry a `bbox` column with row-group statistics, so a bounding-box filter
 * touches only the row groups that intersect it, which is how a city-sized
 * fetch takes minutes rather than the hours a full scan would.
 *
 * One DuckDB instance is kept per source for the life of the process. The
 * first query against a release lists its files and reads every footer;
 * with the metadata caches on, later queries skip that, so the second area
 * fetched in a process costs a fraction of the first. Each fetch is a single
 * streamed query: paging with OFFSET would rescan the release for every page.
 *
 * Rows are turned into the same GeoJSON feature shape the file importers
 * read, so one parser (`overture.ts`, `overture-extents.ts`) serves both.
 * Geometry is decoded from WKB here rather than with DuckDB's spatial
 * extension, so only `httpfs` is needed at runtime.
 */

import {
  DuckDBBlobValue,
  DuckDBGeometryValue,
  DuckDBInstance,
  DuckDBListValue,
  DuckDBStructValue,
  type DuckDBConnection,
} from "@duckdb/node-api";
import type { Bounds } from "./coverage-cells.js";
import type { OverturePlaceFeature } from "./overture.js";
import {
  EXTENT_FAMILY_BY_CLASS,
  EXTENT_FAMILY_BY_SUBTYPE,
  extentFromWkbGeometry,
  polygonsContain,
  type OvertureExtentFeature,
} from "./overture-extents.js";
import { decodeWkb, type WkbGeometry } from "./wkb.js";

export type OvertureTheme = "places" | "base" | "divisions";

/** Where a release's files live. Swapped for local files in tests. */
export interface OvertureSource {
  release: string;
  /** A glob DuckDB's read_parquet accepts for one theme and type. */
  parquetGlob(theme: OvertureTheme, type: string): string;
  /** Whether `httpfs` has to be loaded (S3), or the files are local. */
  remote: boolean;
}

export function s3Source(release: string): OvertureSource {
  return {
    release,
    remote: true,
    parquetGlob: (theme, type) =>
      `s3://overturemaps-us-west-2/release/${release}/theme=${theme}/type=${type}/*`,
  };
}

// The worker shares the API process on Railway, so DuckDB is kept small.
const DUCKDB_MEMORY_LIMIT = "512MB";
const DUCKDB_THREADS = 2;

const instances = new Map<OvertureSource, Promise<DuckDBInstance>>();

async function createInstance(source: OvertureSource): Promise<DuckDBInstance> {
  const instance = await DuckDBInstance.create(":memory:");
  const connection = await instance.connect();
  try {
    await connection.run(`SET GLOBAL memory_limit='${DUCKDB_MEMORY_LIMIT}'; SET GLOBAL threads=${DUCKDB_THREADS};`);
    if (source.remote) {
      await connection.run(`
        INSTALL httpfs; LOAD httpfs;
        SET GLOBAL s3_region='us-west-2';
        SET GLOBAL enable_http_metadata_cache=true;
        SET GLOBAL parquet_metadata_cache=true;
      `);
    }
  } finally {
    connection.closeSync();
  }
  return instance;
}

/** A connection on the source's instance, created on first use. */
async function connect(source: OvertureSource): Promise<DuckDBConnection> {
  let pending = instances.get(source);
  if (!pending) {
    pending = createInstance(source);
    instances.set(source, pending);
    pending.catch(() => instances.delete(source));
  }
  return (await pending).connect();
}

/** Releases the source's instance and its caches. The next fetch starts a new one. */
export async function closeOvertureSource(source: OvertureSource): Promise<void> {
  const pending = instances.get(source);
  if (!pending) {
    return;
  }
  instances.delete(source);
  try {
    (await pending).closeSync();
  } catch {
    // Creation failed; there is nothing to close.
  }
}

/** `WHERE` clause on the release files' bbox column. */
function bboxPredicate(bounds: Bounds): string {
  return `bbox.xmin < ${bounds.east} AND bbox.xmax > ${bounds.west} AND bbox.ymin < ${bounds.north} AND bbox.ymax > ${bounds.south}`;
}

function sqlStringList(values: string[]): string {
  return values.map((value) => `'${value.replace(/'/g, "''")}'`).join(", ");
}

/** Only the polygon kinds `parseOvertureExtent` accepts, so the rest are never read. */
function extentFamilyPredicate(): string {
  return `((subtype || ':' || class) IN (${sqlStringList(Object.keys(EXTENT_FAMILY_BY_CLASS))})
           OR subtype IN (${sqlStringList(Object.keys(EXTENT_FAMILY_BY_SUBTYPE))}))`;
}

type Row = Record<string, unknown>;

/** DuckDB's struct, list and bigint values as plain JSON-shaped data. */
function plain(value: unknown): unknown {
  if (typeof value === "bigint") {
    return Number(value);
  }
  if (value instanceof DuckDBStructValue) {
    const out: Record<string, unknown> = {};
    for (const [key, entry] of Object.entries(value.entries)) {
      out[key] = plain(entry);
    }
    return out;
  }
  if (value instanceof DuckDBListValue) {
    return value.items.map(plain);
  }
  if (value instanceof DuckDBBlobValue) {
    return value.bytes;
  }
  if (Array.isArray(value)) {
    return value.map(plain);
  }
  if (value && typeof value === "object" && Object.getPrototypeOf(value) === Object.prototype) {
    const out: Record<string, unknown> = {};
    for (const [key, entry] of Object.entries(value as Record<string, unknown>)) {
      out[key] = plain(entry);
    }
    return out;
  }
  return value;
}

/**
 * The release files are GeoParquet, which DuckDB 1.5 reads as its native
 * GEOMETRY type; its bytes are WKB, like a plain BLOB column's.
 */
function geometryOf(row: Row): WkbGeometry | null {
  const raw = row.geometry;
  if (raw instanceof DuckDBGeometryValue || raw instanceof DuckDBBlobValue) {
    return decodeWkb(raw.bytes);
  }
  if (raw instanceof Uint8Array) {
    return decodeWkb(raw);
  }
  return null;
}

/** Runs one query and hands its rows over as DuckDB produces them, a chunk at a time. */
async function streamRows(
  connection: DuckDBConnection,
  query: string,
  onRows: (rows: Row[]) => Promise<void>,
): Promise<number> {
  const result = await connection.stream(query);
  let total = 0;
  for await (const chunk of result.yieldRowObjects()) {
    total += chunk.length;
    await onRows(chunk as Row[]);
  }
  return total;
}

/**
 * The columns the parsers use, and no more: whole `names`, `taxonomy` and
 * `addresses` structs carry translations, hierarchies and secondary
 * addresses that would be fetched and decoded only to be dropped.
 */
const PLACE_COLUMNS = `id, geometry, names.primary AS name,
  taxonomy.primary AS primary_category, taxonomy.alternates AS alternate_categories,
  confidence, addresses[1] AS address, websites[1] AS website, phones[1] AS phone, operating_status`;
const EXTENT_COLUMNS = "id, geometry, names.primary AS name, subtype, class";

/** A place row from the release files as the GeoJSON feature `parseOverturePlace` reads. */
export function placeRowToFeature(row: Row): OverturePlaceFeature {
  const geometry = geometryOf(row);
  const properties = plain({
    names: { primary: row.name },
    taxonomy: { primary: row.primary_category, alternates: row.alternate_categories },
    confidence: row.confidence,
    addresses: [row.address],
    websites: [row.website],
    phones: [row.phone],
    operating_status: row.operating_status,
  }) as OverturePlaceFeature["properties"];
  return { id: String(row.id), type: "Feature", geometry, properties };
}

/** A land_use or infrastructure row as the feature `parseOvertureExtent` reads. */
export function extentRowToFeature(row: Row): OvertureExtentFeature {
  const geometry = geometryOf(row);
  return {
    id: String(row.id),
    geometry: geometry ? extentFromWkbGeometry(geometry) : null,
    properties: plain({
      subtype: row.subtype,
      class: row.class,
      names: { primary: row.name },
    }) as OvertureExtentFeature["properties"],
  };
}

/**
 * The place features inside `bounds`, handed to `onBatch` in batches of
 * `batchSize`. The next batch is read while `onBatch` is still working on
 * the previous one; there is never more than one `onBatch` in flight, so
 * batches are written in order.
 */
export async function fetchPlaceFeatures(
  source: OvertureSource,
  bounds: Bounds,
  onBatch: (features: OverturePlaceFeature[]) => Promise<void>,
  batchSize = 500,
): Promise<number> {
  const connection = await connect(source);
  try {
    let pending: OverturePlaceFeature[] = [];
    let inFlight: Promise<void> | null = null;
    const dispatch = async (batch: OverturePlaceFeature[]) => {
      if (inFlight) {
        await inFlight;
      }
      inFlight = onBatch(batch);
      // Awaited on the next dispatch or at the end; this only keeps a
      // rejection from counting as unhandled in the meantime.
      inFlight.catch(() => {});
    };
    const total = await streamRows(
      connection,
      `SELECT ${PLACE_COLUMNS} FROM read_parquet('${source.parquetGlob("places", "place")}', hive_partitioning=1)
       WHERE ${bboxPredicate(bounds)}`,
      async (rows) => {
        for (const row of rows) {
          pending.push(placeRowToFeature(row));
          if (pending.length === batchSize) {
            const batch = pending;
            pending = [];
            await dispatch(batch);
          }
        }
      },
    );
    if (pending.length > 0) {
      await dispatch(pending);
    }
    if (inFlight) {
      await inFlight;
    }
    return total;
  } finally {
    connection.closeSync();
  }
}

/** Named venue grounds (land_use and infrastructure polygons) inside `bounds`. */
export async function fetchExtentFeatures(source: OvertureSource, bounds: Bounds): Promise<OvertureExtentFeature[]> {
  const connection = await connect(source);
  try {
    const features: OvertureExtentFeature[] = [];
    for (const type of ["land_use", "infrastructure"]) {
      await streamRows(
        connection,
        `SELECT ${EXTENT_COLUMNS} FROM read_parquet('${source.parquetGlob("base", type)}', hive_partitioning=1)
         WHERE ${bboxPredicate(bounds)} AND names.primary IS NOT NULL AND ${extentFamilyPredicate()}`,
        async (rows) => {
          for (const row of rows) {
            features.push(extentRowToFeature(row));
          }
        },
      );
    }
    return features;
  } finally {
    connection.closeSync();
  }
}

export interface CityArea {
  name: string;
  subtype: string;
  bounds: Bounds;
}

/**
 * The smallest city-like division area containing the point: a `locality`
 * when there is one, else the `county` (San Francisco, a consolidated
 * city-county, has no locality in Overture). Null when neither holds it.
 */
export async function fetchCityContaining(
  source: OvertureSource,
  point: { latitude: number; longitude: number },
): Promise<CityArea | null> {
  const connection = await connect(source);
  try {
    const rows: Row[] = [];
    await streamRows(
      connection,
      `SELECT geometry, names.primary AS name, subtype, bbox
       FROM read_parquet('${source.parquetGlob("divisions", "division_area")}', hive_partitioning=1)
       WHERE subtype IN ('locality', 'county') AND class = 'land'
         AND bbox.xmin <= ${point.longitude} AND bbox.xmax >= ${point.longitude}
         AND bbox.ymin <= ${point.latitude} AND bbox.ymax >= ${point.latitude}`,
      async (chunk) => {
        rows.push(...chunk);
      },
    );
    const containing = rows
      .map((row) => ({ row, geometry: geometryOf(row) }))
      .filter(({ geometry }) => geometry?.type === "Polygon" || geometry?.type === "MultiPolygon")
      .filter(({ geometry }) => {
        const polygons = geometry!.type === "Polygon" ? [geometry!.coordinates] : geometry!.coordinates;
        return polygonsContain(polygons as [number, number][][][], point.longitude, point.latitude);
      })
      .map(({ row }) => {
        const bbox = plain(row.bbox) as { xmin: number; xmax: number; ymin: number; ymax: number };
        return {
          name: row.name === null || row.name === undefined ? "" : String(row.name),
          subtype: String(row.subtype),
          bounds: { west: bbox.xmin, south: bbox.ymin, east: bbox.xmax, north: bbox.ymax },
        };
      })
      // Smallest first, so a town inside a larger locality wins.
      .sort((first, second) => boxArea(first.bounds) - boxArea(second.bounds));
    return containing.find((area) => area.subtype === "locality") ?? containing.find((area) => area.subtype === "county") ?? null;
  } finally {
    connection.closeSync();
  }
}

function boxArea(bounds: Bounds): number {
  return (bounds.east - bounds.west) * (bounds.north - bounds.south);
}
