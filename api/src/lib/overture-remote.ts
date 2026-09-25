/**
 * Reads Overture Maps data straight from the public release files with
 * DuckDB, no download step. Each release is GeoParquet on S3 whose files
 * carry a `bbox` column with row-group statistics, so a bounding-box filter
 * touches only the row groups that intersect it, which is how a city-sized
 * fetch takes minutes rather than the hours a full scan would.
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
import { extentFromWkbGeometry, polygonsContain, type OvertureExtentFeature } from "./overture-extents.js";
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

const DUCKDB_MEMORY_LIMIT = "512MB";
const DUCKDB_THREADS = 2;

async function openConnection(source: OvertureSource): Promise<DuckDBConnection> {
  const instance = await DuckDBInstance.create(":memory:");
  const connection = await instance.connect();
  await connection.run(`SET memory_limit='${DUCKDB_MEMORY_LIMIT}'; SET threads=${DUCKDB_THREADS};`);
  if (source.remote) {
    await connection.run("INSTALL httpfs; LOAD httpfs; SET s3_region='us-west-2';");
  }
  return connection;
}

/** `WHERE` clause on the release files' bbox column. */
function bboxPredicate(bounds: Bounds): string {
  return `bbox.xmin < ${bounds.east} AND bbox.xmax > ${bounds.west} AND bbox.ymin < ${bounds.north} AND bbox.ymax > ${bounds.south}`;
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

async function readRows(connection: DuckDBConnection, query: string): Promise<Row[]> {
  const reader = await connection.runAndReadAll(query);
  return reader.getRowObjects().map((row) => row as Row);
}

/** A place row from the release files as the GeoJSON feature `parseOverturePlace` reads. */
export function placeRowToFeature(row: Row): OverturePlaceFeature {
  const geometry = geometryOf(row);
  const properties = plain({
    names: row.names,
    taxonomy: row.taxonomy,
    categories: row.categories,
    confidence: row.confidence,
    addresses: row.addresses,
    websites: row.websites,
    phones: row.phones,
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
    properties: plain({ subtype: row.subtype, class: row.class, names: row.names }) as OvertureExtentFeature["properties"],
  };
}

const PLACE_COLUMNS = "id, geometry, names, taxonomy, confidence, addresses, websites, phones, operating_status";
const EXTENT_COLUMNS = "id, geometry, names, subtype, class";

/** The place features inside `bounds`, streamed to `onBatch` in batches. */
export async function fetchPlaceFeatures(
  source: OvertureSource,
  bounds: Bounds,
  onBatch: (features: OverturePlaceFeature[]) => Promise<void>,
  batchSize = 500,
): Promise<number> {
  const connection = await openConnection(source);
  try {
    const glob = source.parquetGlob("places", "place");
    let offset = 0;
    let total = 0;
    // Paged so a dense city never sits in memory at once. DuckDB's parquet
    // scan is deterministic for a fixed query, so OFFSET pages are stable.
    for (;;) {
      const rows = await readRows(
        connection,
        `SELECT ${PLACE_COLUMNS} FROM read_parquet('${glob}', hive_partitioning=1)
         WHERE ${bboxPredicate(bounds)} ORDER BY id LIMIT ${batchSize} OFFSET ${offset}`,
      );
      if (rows.length === 0) {
        break;
      }
      await onBatch(rows.map(placeRowToFeature));
      total += rows.length;
      offset += rows.length;
      if (rows.length < batchSize) {
        break;
      }
    }
    return total;
  } finally {
    connection.closeSync();
  }
}

/** Named venue grounds (land_use and infrastructure polygons) inside `bounds`. */
export async function fetchExtentFeatures(source: OvertureSource, bounds: Bounds): Promise<OvertureExtentFeature[]> {
  const connection = await openConnection(source);
  try {
    const features: OvertureExtentFeature[] = [];
    for (const type of ["land_use", "infrastructure"]) {
      const rows = await readRows(
        connection,
        `SELECT ${EXTENT_COLUMNS} FROM read_parquet('${source.parquetGlob("base", type)}', hive_partitioning=1)
         WHERE ${bboxPredicate(bounds)} AND names.primary IS NOT NULL`,
      );
      features.push(...rows.map(extentRowToFeature));
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
  const connection = await openConnection(source);
  try {
    const rows = await readRows(
      connection,
      `SELECT id, geometry, names, subtype, bbox FROM read_parquet('${source.parquetGlob("divisions", "division_area")}', hive_partitioning=1)
       WHERE subtype IN ('locality', 'county') AND class = 'land'
         AND bbox.xmin <= ${point.longitude} AND bbox.xmax >= ${point.longitude}
         AND bbox.ymin <= ${point.latitude} AND bbox.ymax >= ${point.latitude}`,
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
        const names = plain(row.names) as { primary?: string } | null;
        return {
          name: names?.primary ?? "",
          subtype: String(row.subtype),
          bounds: { west: bbox.xmin, south: bbox.ymin, east: bbox.xmax, north: bbox.ymax },
        };
      });
    return containing.find((area) => area.subtype === "locality") ?? containing.find((area) => area.subtype === "county") ?? null;
  } finally {
    connection.closeSync();
  }
}
