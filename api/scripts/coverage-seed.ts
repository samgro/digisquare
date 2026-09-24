/**
 * Loads whole regions from the Overture release files, straight from S3.
 *
 *   npm run coverage:seed -- bay-area new-york
 *
 * Each region is split into 1 degree tiles and every tile is one fetch, run
 * here rather than through the API's worker so it can be watched. A tile
 * whose cells are all ready is skipped, so a stopped run resumes where it
 * left off. Needs DATABASE_URL and OVERTURE_RELEASE; no rate limits apply.
 */

import "../src/load-environment.js";
import { config } from "../src/config.js";
import { cellsInBounds, groupCellsIntoTiles } from "../src/lib/coverage-cells.js";
import { seedCellsNow } from "../src/lib/coverage-worker.js";
import { s3Source } from "../src/lib/overture-remote.js";
import { findSeedRegion } from "./seed-regions.js";

async function main(): Promise<void> {
  const names = process.argv.slice(2);
  if (names.length === 0) {
    throw new Error("Usage: npm run coverage:seed -- <region> [<region> ...]  (bay-area, new-york)");
  }
  const source = s3Source(config.OVERTURE_RELEASE);
  for (const name of names) {
    const region = findSeedRegion(name);
    const tiles = groupCellsIntoTiles(cellsInBounds(region.bounds));
    console.log(`${region.name}: ${tiles.length} tiles, release ${config.OVERTURE_RELEASE}`);
    for (const [index, tile] of tiles.entries()) {
      const label = `tile ${index + 1}/${tiles.length} (${tile.bounds.west},${tile.bounds.south})`;
      const fetched = await seedCellsNow(source, tile.cells, tile.bounds);
      console.log(`${label}: ${fetched ? "fetched" : "already ready"}`);
    }
  }
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
