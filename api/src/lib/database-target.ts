import { existsSync, readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import dotenv from "dotenv";

/**
 * Where DATABASE_URL points and which file said so, for printing before a
 * migration or seed runs. Worktrees share `api/.env` with the main checkout
 * (production) and override it with `.env.branch`, so the one thing worth
 * knowing before writing to Postgres is which of the two won.
 */
export interface DatabaseTarget {
  host: string;
  database: string;
  /** Neon's endpoint id from the host, e.g. `ep-red-resonance-arexi4zu`, or null elsewhere. */
  neonEndpoint: string | null;
  /** `.env.branch`, `.env`, or `shell` when neither file set it. */
  source: ".env.branch" | ".env" | "shell";
}

const ENVIRONMENT_PATH = fileURLToPath(new URL("../../.env", import.meta.url));
const BRANCH_ENVIRONMENT_PATH = fileURLToPath(new URL("../../../.env.branch", import.meta.url));

function databaseUrlIn(path: string): string | undefined {
  if (!existsSync(path)) {
    return undefined;
  }
  return dotenv.parse(readFileSync(path)).DATABASE_URL;
}

/** Null when DATABASE_URL is unset or not a URL. */
export function describeDatabaseTarget(databaseUrl = process.env.DATABASE_URL): DatabaseTarget | null {
  if (!databaseUrl) {
    return null;
  }
  let url: URL;
  try {
    url = new URL(databaseUrl);
  } catch {
    return null;
  }

  // load-environment.ts applies .env.branch over .env, so whichever file holds
  // the value that won is the source.
  let source: DatabaseTarget["source"] = "shell";
  if (databaseUrlIn(BRANCH_ENVIRONMENT_PATH) === databaseUrl) {
    source = ".env.branch";
  } else if (databaseUrlIn(ENVIRONMENT_PATH) === databaseUrl) {
    source = ".env";
  }

  const endpointMatch = /^(ep-[a-z0-9-]+?)(-pooler)?\./.exec(url.hostname);
  return {
    host: url.hostname,
    database: url.pathname.replace(/^\//, "") || "(default)",
    neonEndpoint: endpointMatch?.[1] ?? null,
    source,
  };
}

/** One line for a terminal, never including credentials. */
export function formatDatabaseTarget(target: DatabaseTarget | null): string {
  if (!target) {
    return "Database: DATABASE_URL is not set";
  }
  const where = target.neonEndpoint ? `Neon endpoint ${target.neonEndpoint}` : target.host;
  const from =
    target.source === ".env"
      ? "from api/.env — in a worktree that is the main checkout's database"
      : `from ${target.source}`;
  return `Database: ${where}, ${target.database} (${from})`;
}
