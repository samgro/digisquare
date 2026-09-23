import { describe, expect, it } from "vitest";
import { DrizzleQueryError } from "drizzle-orm/errors";
import { isUniqueViolation } from "./database-errors.js";

describe("isUniqueViolation", () => {
  it("recognises a bare driver error", () => {
    expect(isUniqueViolation({ code: "23505" })).toBe(true);
  });

  // This is the shape a real conflict actually arrives in: drizzle wraps the
  // driver error, and the Postgres code is only on `cause`.
  it("recognises a driver error wrapped by drizzle", () => {
    const wrapped = new DrizzleQueryError("insert into ...", [], Object.assign(new Error("duplicate key"), { code: "23505" }));
    expect(isUniqueViolation(wrapped)).toBe(true);
  });

  it("ignores other errors", () => {
    expect(isUniqueViolation(new Error("boom"))).toBe(false);
    expect(isUniqueViolation({ code: "23503" })).toBe(false);
    expect(isUniqueViolation(new DrizzleQueryError("select", [], new Error("timeout")))).toBe(false);
    expect(isUniqueViolation(null)).toBe(false);
  });
});
