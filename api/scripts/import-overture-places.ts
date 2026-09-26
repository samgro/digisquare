/**
 * Loads Overture Maps places from a downloaded file into the `places` table.
 *
 *   npm run overture:import -- path/to/places.geojsonseq
 *
 * The file is what the official `overturemaps` CLI downloads for an area:
 *
 *   overturemaps download --bbox=-122.55,37.70,-122.35,37.85 \
 *     -f geojsonseq --type=place -o places.geojsonseq
 *
 * Rows are upserted on the Overture GERS id, stamped with OVERTURE_RELEASE,
 * and the 0.1 degree cells the file covers are marked ready so the coverage
 * worker never fetches them again. Most areas need no file at all: the API
 * fetches an area itself the first time someone searches there (see
 * SETUP.md), and `npm run coverage:seed` loads whole regions.
 */

import "../src/load-environment.js";
import { config } from "../src/config.js";
import { cellForPoint, cellKey, type Cell } from "../src/lib/coverage-cells.js";
import { parseOverturePlace, type OverturePlaceFeature, type OverturePlaceInsert, type SkipReason } from "../src/lib/overture.js";
import { markCells, UPSERT_BATCH_SIZE, upsertOverturePlaces } from "../src/lib/overture-import.js";
import { fileArguments, readGeoJsonFeatures } from "./overture-files.js";

interface ImportTally {
  seen: number;
  changed: number;
  skipped: Record<SkipReason, number>;
  cells: Map<string, Cell>;
}

async function importFile(filePath: string): Promise<ImportTally> {
  const tally: ImportTally = {
    seen: 0,
    changed: 0,
    skipped: { missing_id: 0, missing_name: 0, missing_point: 0, permanently_closed: 0 },
    cells: new Map(),
  };
  let batch: OverturePlaceInsert[] = [];
  const flush = async () => {
    const outcome = await upsertOverturePlaces(batch, config.OVERTURE_RELEASE);
    tally.seen += outcome.seen;
    tally.changed += outcome.changed;
    batch = [];
    process.stdout.write(`\r${tally.seen} places`);
  };
  for await (const feature of readGeoJsonFeatures<OverturePlaceFeature>(filePath)) {
    const parsed = parseOverturePlace(feature);
    if (parsed.skipped) {
      tally.skipped[parsed.skipped] += 1;
      continue;
    }
    batch.push(parsed.row);
    const cell = cellForPoint(parsed.row.latitude!, parsed.row.longitude!);
    tally.cells.set(cellKey(cell), cell);
    if (batch.length >= UPSERT_BATCH_SIZE) {
      await flush();
    }
  }
  await flush();
  process.stdout.write("\n");
  await markCells([...tally.cells.values()], "ready", config.OVERTURE_RELEASE, null);
  return tally;
}

async function main(): Promise<void> {
  for (const filePath of fileArguments("Usage: npm run overture:import -- <places.geojsonseq | places.geojson> [...]")) {
    console.log(`Importing ${filePath}`);
    const tally = await importFile(filePath);
    const skipped = Object.entries(tally.skipped)
      .filter(([, count]) => count > 0)
      .map(([reason, count]) => `${count} ${reason.replace(/_/g, " ")}`);
    console.log(`  ${tally.seen} places (${tally.changed} new or changed), ${tally.cells.size} cells marked ready`);
    console.log(skipped.length > 0 ? `  skipped: ${skipped.join(", ")}` : "  nothing skipped");
  }
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
