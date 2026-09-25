import { drizzle } from "drizzle-orm/neon-http";
import { eq } from "drizzle-orm";
import { neon } from "@neondatabase/serverless";
import { describe, expect, it, vi } from "vitest";
import { checkins as checkinsTable, users as usersTable } from "../db/schema.js";

vi.mock("../db/index.js", () => ({ database: {} }));

const { checkinSocialColumns } = await import("./checkin-social.js");

// Only renders SQL, never connects.
const database = drizzle(neon("postgres://user:password@localhost/database"));

const CURRENT_USER_ID = "550e8400-e29b-41d4-a716-446655440000";

describe("checkinSocialColumns", () => {
  // Without joins Drizzle leaves table names off columns, which once turned
  // the subqueries' `checkins.id` into the like's own id.
  it("ties each subquery to the outer checkin on a single-table select", () => {
    const { sql: query } = database
      .select(checkinSocialColumns(CURRENT_USER_ID))
      .from(checkinsTable)
      .toSQL();

    expect(query.match(/= "checkins"\."id"/g)).toHaveLength(3);
  });

  it("ties each subquery to the outer checkin on a joined select", () => {
    const { sql: query } = database
      .select(checkinSocialColumns(CURRENT_USER_ID))
      .from(checkinsTable)
      .innerJoin(usersTable, eq(usersTable.id, checkinsTable.userId))
      .toSQL();

    expect(query.match(/= "checkins"\."id"/g)).toHaveLength(3);
  });
});
