/**
 * Prints which database the scripts and drizzle-kit will reach, and which
 * env file it came from, so a migration is never run against the wrong one.
 * With NEON_API_KEY set, also names the Neon branch behind the endpoint.
 *
 *   npm run db:branch
 */

import "../src/load-environment.js";
import {
  describeDatabaseTarget,
  formatDatabaseTarget,
  lookupNeonBranch,
} from "../src/lib/database-target.js";

const target = describeDatabaseTarget();
const apiKey = process.env.NEON_API_KEY;

if (target?.neonEndpoint && apiKey) {
  try {
    const branch = await lookupNeonBranch(target.neonEndpoint, apiKey, process.env.NEON_PROJECT_ID);
    console.log(formatDatabaseTarget(target, branch));
    if (!branch) {
      console.log("No project this NEON_API_KEY can see has that endpoint.");
    }
  } catch (error) {
    console.log(formatDatabaseTarget(target));
    console.error(`Couldn't look up the branch name: ${error instanceof Error ? error.message : String(error)}`);
  }
} else {
  console.log(formatDatabaseTarget(target));
  if (target?.neonEndpoint) {
    console.log("Set NEON_API_KEY in api/.env to print the branch's name too (Neon console → Account settings → API keys).");
  }
}
