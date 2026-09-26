import { readdirSync, readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";
import type { RankingFixture } from "../../scripts/ranking-fixture.js";

/**
 * The checkin-ranking scenarios live at the repo root so the iOS tests can
 * read the very same files. Read with `readFileSync` instead of a bare JSON
 * import because NodeNext ESM requires import attributes that vitest's
 * transform doesn't need, and mixing the two conventions produces confusing
 * errors.
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

/** A recorded Foursquare v2 response, from test/fixtures/foursquare. */
export function loadFoursquareFixture(fileName: string): unknown {
  const filePath = path.join(
    path.dirname(fileURLToPath(import.meta.url)),
    "..",
    "fixtures",
    "foursquare",
    fileName,
  );
  return JSON.parse(readFileSync(filePath, "utf-8"));
}
