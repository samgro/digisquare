import { readdirSync, readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";

const sourceDirectory = path.join(path.dirname(fileURLToPath(import.meta.url)), "..");

// The schema defines the table and checkin-queries.ts is the one place allowed
// to query it, because that is where the visibility rule lives.
const ALLOWED_FILES = ["db/schema.ts", "lib/checkin-queries.ts"];

// `checkins` named in an import from the schema, with or without an alias.
const IMPORTS_CHECKINS_TABLE = /import\s*(?:type\s*)?{[^}]*\bcheckins\b[^}]*}\s*from\s*["'][^"']*db\/schema(?:\.js)?["']/;
// Drizzle's relational API reaches tables without importing them.
const USES_RELATIONAL_CHECKINS = /\bquery\s*\.\s*checkins\b/;
// A namespace import hands over every table, checkins included.
const IMPORTS_WHOLE_SCHEMA = /import\s*\*\s*as\s+\w+\s+from\s*["'][^"']*db\/schema(?:\.js)?["']/;

function sourceFiles(directory: string): string[] {
  return readdirSync(directory, { withFileTypes: true }).flatMap((entry) => {
    const entryPath = path.join(directory, entry.name);
    if (entry.isDirectory()) {
      return sourceFiles(entryPath);
    }
    return entry.name.endsWith(".ts") && !entry.name.endsWith(".test.ts") ? [entryPath] : [];
  });
}

describe("checkin access", () => {
  // Every other module has to go through checkin-queries.ts, so a new endpoint
  // cannot read checkins without the rule that hides strangers' checkins.
  it("only lets checkin-queries.ts query the checkins table", () => {
    const offenders = sourceFiles(sourceDirectory)
      .map((filePath) => path.relative(sourceDirectory, filePath).split(path.sep).join("/"))
      .filter((relativePath) => !ALLOWED_FILES.includes(relativePath))
      .filter((relativePath) => {
        const source = readFileSync(path.join(sourceDirectory, relativePath), "utf-8");
        return (
          IMPORTS_CHECKINS_TABLE.test(source) ||
          USES_RELATIONAL_CHECKINS.test(source) ||
          // db/index.ts passes the whole schema to drizzle to build the
          // client, which is not a query.
          (relativePath !== "db/index.ts" && IMPORTS_WHOLE_SCHEMA.test(source))
        );
      });

    expect(offenders).toEqual([]);
  });
});
