/**
 * Attaches venue grounds from Overture's base theme to the places already
 * in the database.
 *
 *   npm run overture:import-extents -- sf-land-use.geojsonseq sf-infrastructure.geojsonseq
 *
 * with files from
 *
 *   overturemaps download --bbox=... -f geojsonseq --type=land_use -o sf-land-use.geojsonseq
 *   overturemaps download --bbox=... -f geojsonseq --type=infrastructure -o sf-infrastructure.geojsonseq
 *
 * Import the places for the same area first: a polygon attaches to the place
 * whose pin it contains and whose category it fits (see extent-matching.ts).
 * The coverage worker does this on its own for areas it fetches.
 */

import "dotenv/config";
import { attachExtents } from "../src/lib/extent-matching.js";
import { parseOvertureExtent, type OvertureExtentFeature, type ParsedExtent } from "../src/lib/overture-extents.js";
import { fileArguments, readGeoJsonFeatures } from "./overture-files.js";

async function main(): Promise<void> {
  const extents: ParsedExtent[] = [];
  let read = 0;
  for (const filePath of fileArguments("Usage: npm run overture:import-extents -- <land_use.geojsonseq> [<infrastructure.geojsonseq> ...]")) {
    for await (const feature of readGeoJsonFeatures<OvertureExtentFeature>(filePath)) {
      read += 1;
      const extent = parseOvertureExtent(feature);
      if (extent) {
        extents.push(extent);
      }
    }
  }
  console.log(`${extents.length} named venue grounds among ${read} features`);
  const attached = await attachExtents(extents);
  for (const attachment of attached) {
    console.log(`  ${attachment.extent.name} -> ${attachment.placeName}`);
  }
  console.log(`${attached.length} attached`);
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
