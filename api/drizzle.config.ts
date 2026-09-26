import { defineConfig } from "drizzle-kit";
import "./src/load-environment.js";
import { describeDatabaseTarget, formatDatabaseTarget } from "./src/lib/database-target.js";

// Every drizzle-kit command says where it is pointed before it does anything,
// so a `db:migrate` from a worktree without `.env.branch` is caught by eye.
console.error(formatDatabaseTarget(describeDatabaseTarget()));

export default defineConfig({
  schema: "./src/db/schema.ts",
  out: "./drizzle",
  dialect: "postgresql",
  dbCredentials: {
    url: process.env.DATABASE_URL!,
  },
});
