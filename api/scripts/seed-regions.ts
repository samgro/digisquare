/**
 * Regions `npm run coverage:seed` can load whole. Bounding boxes over-cover
 * the combined statistical areas a little (some ocean and rural edge); that
 * costs a few empty cells and nothing else.
 */

import type { Bounds } from "../src/lib/coverage-cells.js";

export interface SeedRegion {
  name: string;
  description: string;
  bounds: Bounds;
}

export const seedRegions: SeedRegion[] = [
  {
    name: "soma",
    description:
      "SoMa and downtown San Francisco: the four 0.1 degree cells a nearby search from there checks (its 2 km reach crosses 37.8 north into the Marina row), so the app sees the area as covered. Seeds in a minute or two, for checking a change in the app.",
    bounds: { west: -122.42, south: 37.76, east: -122.38, north: 37.84 },
  },
  {
    name: "sfo",
    description:
      "San Francisco International Airport with South San Francisco and Millbrae, the four cells a search from a terminal checks. For seeing a large venue's grounds rank from a gate.",
    bounds: { west: -122.42, south: 37.56, east: -122.38, north: 37.64 },
  },
  {
    name: "bay-area",
    description:
      "San Jose-San Francisco-Oakland CSA: Alameda, Contra Costa, Marin, Napa, San Francisco, San Mateo, Santa Clara, Solano, Sonoma, Santa Cruz, San Benito, San Joaquin, Stanislaus and Merced counties.",
    bounds: { west: -123.6, south: 36.2, east: -120.0, north: 38.9 },
  },
  {
    name: "new-york",
    description:
      "New York-Newark CSA: New York City, Long Island, the lower Hudson Valley, northern and central New Jersey, Pike County PA and the Connecticut counties in the CSA.",
    bounds: { west: -75.4, south: 39.5, east: -71.8, north: 41.9 },
  },
];

/** Accepts `--soma` as well as `soma`, so a region reads like a flag. */
export function findSeedRegion(name: string): SeedRegion {
  const regionName = name.replace(/^-+/, "");
  const region = seedRegions.find((candidate) => candidate.name === regionName);
  if (!region) {
    throw new Error(`Unknown region "${name}". Known: ${seedRegions.map((candidate) => candidate.name).join(", ")}`);
  }
  return region;
}
