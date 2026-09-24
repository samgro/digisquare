import { and, count, desc, eq, or, sql, type SQL } from "drizzle-orm";
import { database } from "../db/index.js";
import { checkins as checkinsTable, users as usersTable } from "../db/schema.js";
import { friendIdsOf } from "./friendships.js";

/**
 * The only module that reads or writes the checkins table. Routes go through
 * these functions instead of querying it themselves, so no endpoint can forget
 * the rule that you only ever see your own checkins and your friends'.
 * checkin-access.test.ts fails if anything else imports the table.
 */

type CheckinRow = typeof checkinsTable.$inferSelect;
type UserRow = typeof usersTable.$inferSelect;

declare const visibleToViewer: unique symbol;

/**
 * A checkin row that has passed the visibility rule for the signed-in user.
 * Only this module can produce one, and toCheckinResult accepts nothing else,
 * so a row read any other way cannot be sent to a client.
 */
export type VisibleCheckin = CheckinRow & { readonly [visibleToViewer]: true };

export type NewCheckin = Omit<
  typeof checkinsTable.$inferInsert,
  "id" | "userId" | "createdAt" | "updatedAt"
>;

export interface CheckinPage {
  limit: number;
  offset: number;
}

/**
 * Checkins the viewer is allowed to see: their own and their friends'. Anyone
 * else's are filtered out rather than refused, so a request for a stranger's
 * checkins looks the same as one for a user with none.
 */
function isVisibleCheckin(viewerId: string): SQL {
  return or(
    eq(checkinsTable.userId, viewerId),
    sql`${checkinsTable.userId} in ${friendIdsOf(viewerId)}`,
  ) as SQL;
}

// Rows are only cast after the query that filtered or owned them.
function markVisible(row: CheckinRow): VisibleCheckin {
  return row as VisibleCheckin;
}

export async function listVisibleCheckins(
  viewerId: string,
  filters: { userId?: string; googlePlaceId?: string },
  page: CheckinPage,
): Promise<VisibleCheckin[]> {
  const conditions = [
    isVisibleCheckin(viewerId),
    filters.userId ? eq(checkinsTable.userId, filters.userId) : undefined,
    filters.googlePlaceId ? eq(checkinsTable.googlePlaceId, filters.googlePlaceId) : undefined,
  ].filter((condition) => condition !== undefined);

  const rows = await database
    .select()
    .from(checkinsTable)
    .where(and(...conditions))
    .orderBy(desc(checkinsTable.createdAt))
    .limit(page.limit)
    .offset(page.offset);
  return rows.map(markVisible);
}

/** Each visible checkin with the user who made it, newest first. */
export async function listVisibleCheckinsWithUsers(
  viewerId: string,
  page: CheckinPage,
): Promise<{ checkin: VisibleCheckin; user: UserRow }[]> {
  const rows = await database
    .select({ checkin: checkinsTable, user: usersTable })
    .from(checkinsTable)
    .innerJoin(usersTable, eq(usersTable.id, checkinsTable.userId))
    .where(isVisibleCheckin(viewerId))
    .orderBy(desc(checkinsTable.createdAt))
    .limit(page.limit)
    .offset(page.offset);
  return rows.map((row) => ({ checkin: markVisible(row.checkin), user: row.user }));
}

/** A stranger's checkin is the same undefined as one that does not exist. */
export async function findVisibleCheckin(
  viewerId: string,
  checkinId: string,
): Promise<VisibleCheckin | undefined> {
  const [row] = await database
    .select()
    .from(checkinsTable)
    .where(and(eq(checkinsTable.id, checkinId), isVisibleCheckin(viewerId)));
  return row ? markVisible(row) : undefined;
}

export async function createOwnCheckin(
  userId: string,
  values: NewCheckin,
): Promise<VisibleCheckin> {
  const [created] = await database
    .insert(checkinsTable)
    .values({ ...values, userId })
    .returning();
  return markVisible(created);
}

/**
 * Scoped by owner, so a checkin that exists but belongs to someone else is
 * the same undefined as one that does not exist. A 403 would confirm the id
 * is real.
 */
export async function updateOwnCheckin(
  userId: string,
  checkinId: string,
  values: Pick<NewCheckin, "message">,
): Promise<VisibleCheckin | undefined> {
  const [updated] = await database
    .update(checkinsTable)
    .set(values)
    .where(and(eq(checkinsTable.id, checkinId), eq(checkinsTable.userId, userId)))
    .returning();
  return updated ? markVisible(updated) : undefined;
}

/**
 * How many checkins someone has made. Public on purpose: profiles show the
 * count to anyone, friend or not, while the checkins themselves stay private.
 */
export async function countCheckinsBy(userId: string): Promise<number> {
  const [total] = await database
    .select({ value: count() })
    .from(checkinsTable)
    .where(eq(checkinsTable.userId, userId));
  return total?.value ?? 0;
}
