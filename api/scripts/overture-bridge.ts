/**
 * Reads the configured release's bridge files and writes, for every Overture
 * place in the database, how many providers matched it, and for every
 * imported Foursquare venue, which Overture place it is. Run after a seed or
 * refresh; a scan of the whole release, so minutes rather than seconds.
 *
 *   npm run overture:bridge
 */

import "../src/load-environment.js";
import { config } from "../src/config.js";
import { applyBridgeMatches } from "../src/lib/overture-bridge.js";
import { closeOvertureSource, s3Source } from "../src/lib/overture-remote.js";

async function main(): Promise<void> {
  const source = s3Source(config.OVERTURE_RELEASE);
  const startedAt = Date.now();
  const outcome = await applyBridgeMatches(source, (message) => console.log(message));
  await closeOvertureSource(source);
  console.log(
    `${outcome.placesUpdated} of ${outcome.placeCount} places changed provider count; ` +
      `${outcome.venuesMatched} of ${outcome.venueCount} Foursquare venues newly matched; ` +
      `${Math.round((Date.now() - startedAt) / 1000)} s`,
  );
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
