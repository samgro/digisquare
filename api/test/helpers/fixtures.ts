import { readdirSync, readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";
import type { RankingFixture } from "../../scripts/ranking-fixture.js";

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

/**
 * The checkin-ranking scenarios live at the repo root so the iOS tests can
 * read the very same files.
 */
export const rankingFixturesDirectory = path.join(
  path.dirname(fileURLToPath(import.meta.url)),
  "..",
  "..",
  "..",
  "fixtures",
  "ranking",
);

export function listRankingFixtureNames(): string[] {
  return readdirSync(rankingFixturesDirectory)
    .filter((fileName) => fileName.endsWith(".json"))
    .map((fileName) => fileName.replace(/\.json$/, ""))
    .sort();
}

export function loadRankingFixture(name: string): RankingFixture {
  const filePath = path.join(rankingFixturesDirectory, `${name}.json`);
  return JSON.parse(readFileSync(filePath, "utf-8")) as RankingFixture;
}
