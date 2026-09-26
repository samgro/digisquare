import { describe, expect, it } from "vitest";
import { describeDatabaseTarget, formatDatabaseTarget } from "./database-target.js";

describe("describeDatabaseTarget", () => {
  it("names the Neon endpoint without the pooler suffix and never the password", () => {
    const target = describeDatabaseTarget(
      "postgres://neondb_owner:hunter2@ep-red-resonance-arexi4zu-pooler.c-2.us-east-1.aws.neon.tech/neondb?sslmode=require",
    );
    expect(target).toMatchObject({
      host: "ep-red-resonance-arexi4zu-pooler.c-2.us-east-1.aws.neon.tech",
      database: "neondb",
      neonEndpoint: "ep-red-resonance-arexi4zu",
    });
    expect(formatDatabaseTarget(target)).not.toContain("hunter2");
    expect(formatDatabaseTarget(target)).toContain("ep-red-resonance-arexi4zu");
  });

  it("falls back to the host for a database that is not on Neon", () => {
    const target = describeDatabaseTarget("postgres://user:password@localhost:5432/hackysack_test");
    expect(target?.neonEndpoint).toBeNull();
    expect(formatDatabaseTarget(target)).toContain("localhost, hackysack_test");
  });

  it("says so when nothing is set or the value is not a url", () => {
    expect(describeDatabaseTarget("")).toBeNull();
    expect(describeDatabaseTarget("not a url")).toBeNull();
    expect(formatDatabaseTarget(null)).toBe("Database: DATABASE_URL is not set");
  });
});
