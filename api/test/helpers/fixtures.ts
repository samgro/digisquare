import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";

const fixturesDirectory = path.join(
  path.dirname(fileURLToPath(import.meta.url)),
  "..",
  "fixtures",
  "google",
);

/**
 * Loads a recorded Google Places fixture by filename. Uses `readFileSync`
 * instead of a bare JSON import because NodeNext ESM requires import
 * attributes (`with { type: "json" }`) that vitest's transform doesn't need,
 * and mixing the two conventions produces confusing errors.
 */
export function loadGoogleFixture(fileName: string): unknown {
  const filePath = path.join(fixturesDirectory, fileName);
  return JSON.parse(readFileSync(filePath, "utf-8"));
}
