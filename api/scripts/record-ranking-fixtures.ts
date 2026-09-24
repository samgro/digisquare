/**
 * Records `/places` responses for the checkin-ranking scenarios from a
 * running Hackysack API whose database holds imported Overture data for the
 * scenarios' areas (see SETUP.md).
 *
 *   HACKYSACK_API_URL=http://localhost:3000 npm run fixtures:record            # every scenario
 *   HACKYSACK_API_URL=http://localhost:3000 npm run fixtures:record -- sfo-terminal-2
 *
 * For each scenario it issues the very request the app makes from where the
 * user is standing and writes `fixtures/ranking/<name>.json`. Histories and
 * cases are regenerated from ranking-scenarios.ts so the whole file is
 * reproducible from source plus the recording.
 */

import "../src/load-environment.js";
import { mkdirSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import type { PlaceResult } from "../src/lib/place-result.js";
import { buildRankingFixture } from "./ranking-fixture.js";
import { rankingScenarios, type RankingScenarioDefinition } from "./ranking-scenarios.js";

const fixturesDirectory = path.join(
  path.dirname(fileURLToPath(import.meta.url)),
  "..",
  "..",
  "fixtures",
  "ranking",
);

function apiBaseUrl(): string {
  const baseUrl = process.env.HACKYSACK_API_URL;
  if (!baseUrl) {
    throw new Error("HACKYSACK_API_URL is not set (for example http://localhost:3000)");
  }
  return baseUrl.replace(/\/$/, "");
}

async function fetchPlaces(definition: RankingScenarioDefinition): Promise<PlaceResult[]> {
  const url = new URL(`${apiBaseUrl()}/places`);
  url.searchParams.set("lat", String(definition.fix.latitude));
  url.searchParams.set("lng", String(definition.fix.longitude));
  url.searchParams.set("accuracy", String(definition.horizontalAccuracy));
  if (definition.radius !== undefined) {
    url.searchParams.set("radius", String(definition.radius));
  }
  const response = await fetch(url);
  if (!response.ok) {
    throw new Error(`GET ${url} failed (${response.status}): ${await response.text()}`);
  }
  const body = (await response.json()) as { results: PlaceResult[] };
  return body.results;
}

async function recordScenario(definition: RankingScenarioDefinition): Promise<void> {
  const places = await fetchPlaces(definition);
  console.log(`${definition.name}: ${places.length} places around ${definition.fix.latitude}, ${definition.fix.longitude}`);
  if (places.length === 0) {
    throw new Error(
      `Scenario ${definition.name}: the API returned no places. Import Overture data for this area first (see SETUP.md).`,
    );
  }

  const fixture = buildRankingFixture(definition, places, new Date().toISOString());

  mkdirSync(fixturesDirectory, { recursive: true });
  const filePath = path.join(fixturesDirectory, `${definition.name}.json`);
  writeFileSync(filePath, `${JSON.stringify(fixture, null, 2)}\n`);
  console.log(`  wrote ${path.relative(process.cwd(), filePath)}`);
}

async function main(): Promise<void> {
  const requestedNames = process.argv.slice(2);
  const selected = requestedNames.length
    ? rankingScenarios.filter((scenario) => requestedNames.includes(scenario.name))
    : rankingScenarios;

  const unknown = requestedNames.filter(
    (name) => !rankingScenarios.some((scenario) => scenario.name === name),
  );
  if (unknown.length > 0) {
    throw new Error(
      `Unknown scenario(s): ${unknown.join(", ")}. Known: ${rankingScenarios
        .map((scenario) => scenario.name)
        .join(", ")}`,
    );
  }

  for (const scenario of selected) {
    await recordScenario(scenario);
  }
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
