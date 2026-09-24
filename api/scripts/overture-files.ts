/**
 * Reads GeoJSON the `overturemaps` CLI writes: newline-delimited
 * (`geojsonseq`, streamed, any size) or a plain FeatureCollection
 * (`geojson`, read whole).
 */

import { createReadStream, readFileSync } from "node:fs";
import { createInterface } from "node:readline";

export async function* readGeoJsonFeatures<Feature>(filePath: string): AsyncGenerator<Feature> {
  if (filePath.endsWith(".geojsonseq") || filePath.endsWith(".ndjson") || filePath.endsWith(".jsonl")) {
    const lines = createInterface({ input: createReadStream(filePath), crlfDelay: Infinity });
    for await (const line of lines) {
      // RFC 8142 allows a record separator before each line.
      const trimmed = line.replace(/^\u001e/, "").trim();
      if (trimmed.length > 0) {
        yield JSON.parse(trimmed) as Feature;
      }
    }
    return;
  }

  const document = JSON.parse(readFileSync(filePath, "utf-8")) as {
    type?: string;
    features?: Feature[];
  };
  if (document.type !== "FeatureCollection" || !Array.isArray(document.features)) {
    throw new Error(`${filePath} is not a GeoJSON FeatureCollection`);
  }
  yield* document.features;
}

/** The scenario or file names after `--`, with a usage error when empty. */
export function fileArguments(usage: string): string[] {
  const filePaths = process.argv.slice(2);
  if (filePaths.length === 0) {
    throw new Error(usage);
  }
  return filePaths;
}
