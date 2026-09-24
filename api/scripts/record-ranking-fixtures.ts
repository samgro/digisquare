/**
 * Records real Google Places responses for the checkin-ranking scenarios.
 *
 *   GOOGLE_PLACES_API_KEY=... npm run fixtures:record            # every scenario
 *   GOOGLE_PLACES_API_KEY=... npm run fixtures:record -- sfo-terminal-2
 *
 * For each scenario it resolves the anchor place with Text Search, works out
 * where the user is standing, issues the same two Nearby Search calls the API
 * makes (request bodies included, so the API tests replay them verbatim) and
 * writes `fixtures/ranking/<name>.json`. Each scenario costs three billable
 * requests. Histories and cases are regenerated from ranking-scenarios.ts so
 * the whole file is reproducible from source plus the recording.
 */

import "dotenv/config";
import { mkdirSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import {
  largeVenueSearchParams,
  nearbySearchRequestBody,
  postPlacesSearch,
  shouldSearchByDistance,
  type GooglePlace,
} from "../src/lib/google-places.js";
import { buildRankingFixture, offsetCoordinate, type RecordedGoogleData } from "./ranking-fixture.js";
import { rankingScenarios, type RankingScenarioDefinition } from "./ranking-scenarios.js";

const DEFAULT_RADIUS = 1500;

const fixturesDirectory = path.join(
  path.dirname(fileURLToPath(import.meta.url)),
  "..",
  "..",
  "fixtures",
  "ranking",
);

async function resolveAnchor(definition: RankingScenarioDefinition): Promise<GooglePlace> {
  const response = await postPlacesSearch("searchText", {
    textQuery: definition.anchorQuery,
    maxResultCount: 1,
  });
  const anchor = response.places?.[0];
  if (!anchor?.location) {
    throw new Error(
      `Scenario ${definition.name}: Text Search found nothing for "${definition.anchorQuery}"`,
    );
  }
  return anchor;
}

async function recordScenario(definition: RankingScenarioDefinition): Promise<void> {
  const anchor = await resolveAnchor(definition);
  const anchorLocation = anchor.location!;
  console.log(
    `${definition.name}: anchor "${anchor.displayName?.text ?? anchor.id}" at ${anchorLocation.latitude}, ${anchorLocation.longitude}`,
  );

  const fix = offsetCoordinate(anchorLocation, definition.offsetMeters);
  const radius = definition.radius ?? DEFAULT_RADIUS;

  const largeVenueRequest = nearbySearchRequestBody(largeVenueSearchParams({ ...fix, radius }));
  const google: RecordedGoogleData = {
    largeVenues: {
      request: largeVenueRequest,
      response: await postPlacesSearch("searchNearby", largeVenueRequest),
    },
  };
  if (shouldSearchByDistance(definition.horizontalAccuracy)) {
    const distanceRequest = nearbySearchRequestBody({ ...fix, radius, rankPreference: "DISTANCE" });
    google.distance = {
      request: distanceRequest,
      response: await postPlacesSearch("searchNearby", distanceRequest),
    };
  }

  const fixture = buildRankingFixture(definition, anchorLocation, google, new Date().toISOString());

  mkdirSync(fixturesDirectory, { recursive: true });
  const filePath = path.join(fixturesDirectory, `${definition.name}.json`);
  writeFileSync(filePath, `${JSON.stringify(fixture, null, 2)}\n`);
  console.log(`${definition.name}: wrote ${fixture.places.length} places to ${filePath}`);
}

async function main(): Promise<void> {
  if (!process.env.GOOGLE_PLACES_API_KEY) {
    console.error("GOOGLE_PLACES_API_KEY is not set; export it or put it in api/.env");
    process.exit(1);
  }

  const requestedNames = process.argv.slice(2);
  const selected =
    requestedNames.length === 0
      ? rankingScenarios
      : rankingScenarios.filter((scenario) => requestedNames.includes(scenario.name));
  const unknownNames = requestedNames.filter(
    (name) => !rankingScenarios.some((scenario) => scenario.name === name),
  );
  if (unknownNames.length > 0) {
    console.error(
      `Unknown scenario(s): ${unknownNames.join(", ")}. Known: ${rankingScenarios
        .map((scenario) => scenario.name)
        .join(", ")}`,
    );
    process.exit(1);
  }

  for (const scenario of selected) {
    await recordScenario(scenario);
  }
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
