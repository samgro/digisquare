import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { DuckDBInstance } from "@duckdb/node-api";
import type { OvertureSource } from "../../src/lib/overture-remote.js";

interface SampleRow {
  id: string;
  geometry: { __wkb_hex__: string };
  names?: { primary?: string | null } | null;
  taxonomy?: { primary?: string | null; hierarchy?: string[] | null; alternates?: string[] | null } | null;
  confidence?: number | null;
  addresses?: { freeform?: string | null; locality?: string | null; postcode?: string | null; region?: string | null; country?: string | null }[] | null;
  websites?: string[] | null;
  phones?: string[] | null;
  operating_status?: string | null;
  subtype?: string;
  class?: string;
  bbox: { xmin: number; xmax: number; ymin: number; ymax: number };
}

export interface OvertureSamples {
  release: string;
  places: SampleRow[];
  land_use: SampleRow[];
  infrastructure: SampleRow[];
  division_area: SampleRow[];
}

/** Real rows from the 2026-09-23 release, trimmed to a handful. */
export function loadOvertureSamples(): OvertureSamples {
  const filePath = path.join(
    path.dirname(fileURLToPath(import.meta.url)),
    "..",
    "fixtures",
    "overture",
    "release-2026-09-23-samples.json",
  );
  return JSON.parse(readFileSync(filePath, "utf-8")) as OvertureSamples;
}

function literal(value: unknown): string {
  if (value === null || value === undefined) {
    return "NULL";
  }
  if (typeof value === "number") {
    return String(value);
  }
  if (typeof value === "string") {
    return `'${value.replace(/'/g, "''")}'`;
  }
  if (Array.isArray(value)) {
    return `[${value.map(literal).join(", ")}]`;
  }
  return `{${Object.entries(value as Record<string, unknown>)
    .map(([key, entry]) => `'${key}': ${literal(entry)}`)
    .join(", ")}}`;
}

/** A struct literal typed so a NULL field still gets the right column type. */
function structLiteral(value: Record<string, unknown> | null | undefined, typed: string): string {
  return value ? `${literal(value)}::${typed}` : `NULL::${typed}`;
}

const NAMES_TYPE = "STRUCT(\"primary\" VARCHAR)";
const TAXONOMY_TYPE = "STRUCT(\"primary\" VARCHAR, hierarchy VARCHAR[], alternates VARCHAR[])";
const ADDRESS_TYPE = "STRUCT(freeform VARCHAR, locality VARCHAR, postcode VARCHAR, region VARCHAR, country VARCHAR)[]";
const BBOX_TYPE = "STRUCT(xmin DOUBLE, xmax DOUBLE, ymin DOUBLE, ymax DOUBLE)";

function placeSelect(row: SampleRow): string {
  const names = row.names ? { primary: row.names.primary ?? null } : null;
  const taxonomy = row.taxonomy
    ? { primary: row.taxonomy.primary ?? null, hierarchy: row.taxonomy.hierarchy ?? null, alternates: row.taxonomy.alternates ?? null }
    : null;
  return `SELECT ${literal(row.id)} AS id, from_hex(${literal(row.geometry.__wkb_hex__)}) AS geometry,
    ${structLiteral(names, NAMES_TYPE)} AS names, ${structLiteral(taxonomy, TAXONOMY_TYPE)} AS taxonomy,
    ${literal(row.confidence ?? null)}::DOUBLE AS confidence,
    ${row.addresses ? literal(row.addresses) : "NULL"}::${ADDRESS_TYPE} AS addresses,
    ${row.websites ? literal(row.websites) : "NULL"}::VARCHAR[] AS websites,
    ${row.phones ? literal(row.phones) : "NULL"}::VARCHAR[] AS phones,
    ${literal(row.operating_status ?? null)}::VARCHAR AS operating_status,
    ${structLiteral(row.bbox, BBOX_TYPE)} AS bbox`;
}

function baseSelect(row: SampleRow): string {
  const names = row.names ? { primary: row.names.primary ?? null } : null;
  return `SELECT ${literal(row.id)} AS id, from_hex(${literal(row.geometry.__wkb_hex__)}) AS geometry,
    ${structLiteral(names, NAMES_TYPE)} AS names, ${literal(row.subtype ?? null)}::VARCHAR AS subtype,
    ${literal(row.class ?? null)}::VARCHAR AS class, ${structLiteral(row.bbox, BBOX_TYPE)} AS bbox`;
}

/**
 * Writes the samples to parquet files laid out like a release, and returns
 * a source pointing at them, so the fetch code runs without S3 or httpfs.
 */
export async function writeSampleRelease(samples: OvertureSamples = loadOvertureSamples()): Promise<OvertureSource> {
  const directory = mkdtempSync(path.join(tmpdir(), "overture-release-"));
  const instance = await DuckDBInstance.create(":memory:");
  const connection = await instance.connect();
  const write = async (name: string, selects: string[]) => {
    const filePath = path.join(directory, `${name}.parquet`);
    await connection.run(`COPY (${selects.join(" UNION ALL ")}) TO '${filePath}' (FORMAT PARQUET)`);
  };
  await write("places-place", samples.places.map(placeSelect));
  await write("base-land_use", samples.land_use.filter((row) => !("geometry_note" in row)).map(baseSelect));
  await write("base-infrastructure", samples.infrastructure.map(baseSelect));
  await write(
    "divisions-division_area",
    samples.division_area.map(
      (row) =>
        `SELECT ${literal(row.id)} AS id, from_hex(${literal(row.geometry.__wkb_hex__)}) AS geometry,
         ${structLiteral(row.names ? { primary: row.names.primary ?? null } : null, NAMES_TYPE)} AS names,
         ${literal(row.subtype ?? null)}::VARCHAR AS subtype, ${literal(row.class ?? null)}::VARCHAR AS class,
         ${structLiteral(row.bbox, BBOX_TYPE)} AS bbox`,
    ),
  );
  connection.closeSync();
  return {
    release: samples.release,
    remote: false,
    parquetGlob: (theme, type) => path.join(directory, `${theme}-${type}.parquet`),
  };
}
