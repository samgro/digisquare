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

export function findSeedRegion(name: string): SeedRegion {
  const region = seedRegions.find((candidate) => candidate.name === name);
  if (!region) {
    throw new Error(`Unknown region "${name}". Known: ${seedRegions.map((candidate) => candidate.name).join(", ")}`);
  }
  return region;
}
