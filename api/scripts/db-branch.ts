/**
 * Prints which database the scripts and drizzle-kit will reach, and which
 * env file it came from, so a migration is never run against the wrong one.
 *
 *   npm run db:branch
 */

import "../src/load-environment.js";
import { describeDatabaseTarget, formatDatabaseTarget } from "../src/lib/database-target.js";

console.log(formatDatabaseTarget(describeDatabaseTarget()));
