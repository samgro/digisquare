/**
 * Loads `api/.env`, then `api/.env.branch` on top of it.
 *
 * `.env.branch` is gitignored and optional. A worktree uses it to point at
 * its own Neon branch, so migrations and scripts run there instead of against
 * the database in `.env`. It overrides variables that are already set, not
 * just ones from `.env`: drizzle-kit loads `.env` itself before reading
 * drizzle.config.ts, so without the override `db:migrate` would still reach
 * the `.env` database. That also means a `DATABASE_URL=… npm run db:migrate`
 * from the shell is overridden; to reach the `.env` database on purpose from
 * a checkout that has a `.env.branch`, set `SKIP_ENV_BRANCH=1`.
 */
import { fileURLToPath } from "node:url";
import dotenv from "dotenv";

const BRANCH_ENVIRONMENT_PATH = fileURLToPath(new URL("../.env.branch", import.meta.url));

dotenv.config({ quiet: true });
if (process.env.SKIP_ENV_BRANCH !== "1") {
  dotenv.config({ path: BRANCH_ENVIRONMENT_PATH, override: true, quiet: true });
}
