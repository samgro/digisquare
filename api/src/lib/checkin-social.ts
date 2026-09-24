import { and, eq, sql } from "drizzle-orm";
import { database } from "../db/index.js";
import {
  checkinComments as checkinCommentsTable,
  checkinLikes as checkinLikesTable,
  checkins as checkinsTable,
  users as usersTable,
} from "../db/schema.js";
import { isVisibleCheckin } from "./friendships.js";
import { toUserSummary } from "./user-result.js";

export interface CheckinSocial {
  likeCount: number;
  commentCount: number;
  likedByMe: boolean;
}

/**
 * Like and comment totals for the checkin in the outer query, plus whether
 * the caller is among the likers. Spread into a `select({...})` next to the
 * checkin row so a feed costs one query, not one per row.
 */
export function checkinSocialColumns(currentUserId: string) {
  return {
    likeCount: sql<number>`(
      select count(*) from ${checkinLikesTable}
      where ${checkinLikesTable.checkinId} = ${checkinsTable.id}
    )`.mapWith(Number),
    commentCount: sql<number>`(
      select count(*) from ${checkinCommentsTable}
      where ${checkinCommentsTable.checkinId} = ${checkinsTable.id}
    )`.mapWith(Number),
    likedByMe: sql<boolean>`exists (
      select 1 from ${checkinLikesTable}
      where ${checkinLikesTable.checkinId} = ${checkinsTable.id}
      and ${checkinLikesTable.userId} = ${currentUserId}
    )`.mapWith(Boolean),
  };
}

/** The social columns for one checkin, for routes that just changed them. */
export async function loadCheckinSocial(
  checkinId: string,
  currentUserId: string,
): Promise<CheckinSocial | undefined> {
  const [social] = await database
    .select(checkinSocialColumns(currentUserId))
    .from(checkinsTable)
    .where(eq(checkinsTable.id, checkinId));
  return social;
}

/**
 * The checkin as the caller may see it, or nothing: a stranger's checkin and
 * a friend's private one both come back undefined, so the routes built on
 * this answer the same 404 for "does not exist" and "not yours to see".
 */
export async function findVisibleCheckin(checkinId: string, currentUserId: string) {
  const [checkin] = await database
    .select({ id: checkinsTable.id, userId: checkinsTable.userId })
    .from(checkinsTable)
    .where(and(eq(checkinsTable.id, checkinId), isVisibleCheckin(currentUserId)));
  return checkin;
}

type CommentRow = typeof checkinCommentsTable.$inferSelect;
type UserRow = typeof usersTable.$inferSelect;

export function toCommentResult(comment: CommentRow, user: UserRow) {
  return {
    id: comment.id,
    checkinId: comment.checkinId,
    body: comment.body,
    createdAt: comment.createdAt,
    user: toUserSummary(user),
  };
}
