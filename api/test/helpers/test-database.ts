import path from "node:path";
import { fileURLToPath } from "node:url";
import { PGlite } from "@electric-sql/pglite";
import { drizzle } from "drizzle-orm/pglite";
import { migrate } from "drizzle-orm/pglite/migrator";
import * as schema from "../../src/db/schema.js";

const migrationsFolder = path.join(
  path.dirname(fileURLToPath(import.meta.url)),
  "..",
  "..",
  "drizzle",
);

/**
 * A real Postgres, running in-process with PGlite and migrated with the same
 * files as production. For tests where the SQL itself is what needs proving,
 * such as who can see whose checkins. Everything else uses the faster
 * stub-database.ts.
 */
export async function createTestDatabase() {
  const client = new PGlite();
  const database = drizzle(client, { schema });
  await migrate(database, { migrationsFolder });
  return { database, close: () => client.close() };
}
