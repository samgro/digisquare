/**
 * Loads `api/.env`, then `.env.branch` at the repo root on top of it.
 *
 * `.env.branch` is gitignored and optional. A worktree uses it to point at
 * its own Neon branch, so migrations and scripts run there instead of against
 * the database in `.env`. It overrides variables that are already set, not
 * just ones from `.env`: drizzle-kit loads `.env` itself before reading
 * drizzle.config.ts, so without the override `db:migrate` would still reach
 * the `.env` database.
 */
import { fileURLToPath } from "node:url";
import dotenv from "dotenv";

const BRANCH_ENVIRONMENT_PATH = fileURLToPath(new URL("../../.env.branch", import.meta.url));

dotenv.config({ quiet: true });
dotenv.config({ path: BRANCH_ENVIRONMENT_PATH, override: true, quiet: true });
