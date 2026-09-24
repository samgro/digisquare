/**
 * Loads Overture Maps places into the `places` table.
 *
 *   npm run overture:import -- path/to/places.geojsonseq
 *   npm run overture:import -- path/to/places.geojson
 *
 * The file is what the official `overturemaps` CLI downloads for an area:
 *
 *   overturemaps download --bbox=-122.55,37.70,-122.35,37.85 \
 *     -f geojsonseq --type=place -o places.geojsonseq
 *
 * Both newline-delimited GeoJSON (`geojsonseq`, streamed, any size) and a
 * plain FeatureCollection (`geojson`, read whole) are accepted. Rows are
 * upserted on the Overture GERS id, so re-running with a newer release
 * updates places in place and never duplicates them. Checkins keep pointing
 * at the same rows.
 */

import "dotenv/config";
import { createReadStream, readFileSync } from "node:fs";
import { createInterface } from "node:readline";
import { sql } from "drizzle-orm";
import { database } from "../src/db/index.js";
import { places } from "../src/db/schema.js";
import { parseOverturePlace, type OverturePlaceFeature, type OverturePlaceInsert, type SkipReason } from "../src/lib/overture.js";

const BATCH_SIZE = 500;

interface ImportTally {
  upserted: number;
  skipped: Record<SkipReason, number>;
}

async function upsertBatch(rows: OverturePlaceInsert[]): Promise<void> {
  if (rows.length === 0) {
    return;
  }
  await database
    .insert(places)
    .values(rows)
    .onConflictDoUpdate({
      target: places.overtureId,
      set: {
        name: sql`excluded.name`,
        primaryType: sql`excluded.primary_type`,
        types: sql`excluded.types`,
        addressStreet: sql`excluded.address_street`,
        addressLocality: sql`excluded.address_locality`,
        addressRegion: sql`excluded.address_region`,
        addressPostcode: sql`excluded.address_postcode`,
        addressCountry: sql`excluded.address_country`,
        latitude: sql`excluded.latitude`,
        longitude: sql`excluded.longitude`,
        confidence: sql`excluded.confidence`,
        website: sql`excluded.website`,
        phone: sql`excluded.phone`,
        updatedAt: sql`now()`,
      },
    });
}

async function* readFeatures(filePath: string): AsyncGenerator<OverturePlaceFeature> {
  if (filePath.endsWith(".geojsonseq") || filePath.endsWith(".ndjson") || filePath.endsWith(".jsonl")) {
    const lines = createInterface({ input: createReadStream(filePath), crlfDelay: Infinity });
    for await (const line of lines) {
      // RFC 8142 allows a record separator before each line.
      const trimmed = line.replace(/^\u001e/, "").trim();
      if (trimmed.length > 0) {
        yield JSON.parse(trimmed) as OverturePlaceFeature;
      }
    }
    return;
  }

  const document = JSON.parse(readFileSync(filePath, "utf-8")) as {
    type?: string;
    features?: OverturePlaceFeature[];
  };
  if (document.type !== "FeatureCollection" || !Array.isArray(document.features)) {
    throw new Error(`${filePath} is not a GeoJSON FeatureCollection`);
  }
  yield* document.features;
}

async function importFile(filePath: string): Promise<ImportTally> {
  const tally: ImportTally = {
    upserted: 0,
    skipped: { missing_id: 0, missing_name: 0, missing_point: 0, permanently_closed: 0 },
  };
  let batch: OverturePlaceInsert[] = [];
  for await (const feature of readFeatures(filePath)) {
    const parsed = parseOverturePlace(feature);
    if (parsed.skipped) {
      tally.skipped[parsed.skipped] += 1;
      continue;
    }
    batch.push(parsed.row);
    if (batch.length >= BATCH_SIZE) {
      await upsertBatch(batch);
      tally.upserted += batch.length;
      batch = [];
      process.stdout.write(`\r${tally.upserted} places upserted`);
    }
  }
  await upsertBatch(batch);
  tally.upserted += batch.length;
  process.stdout.write(`\r${tally.upserted} places upserted\n`);
  return tally;
}

async function main(): Promise<void> {
  const filePaths = process.argv.slice(2);
  if (filePaths.length === 0) {
    throw new Error("Usage: npm run overture:import -- <places.geojsonseq | places.geojson> [...]");
  }
  for (const filePath of filePaths) {
    console.log(`Importing ${filePath}`);
    const tally = await importFile(filePath);
    const skipped = Object.entries(tally.skipped)
      .filter(([, count]) => count > 0)
      .map(([reason, count]) => `${count} ${reason.replace(/_/g, " ")}`);
    console.log(skipped.length > 0 ? `  skipped: ${skipped.join(", ")}` : "  nothing skipped");
  }
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
