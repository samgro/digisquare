import { and, eq, inArray, or, sql, type SQL } from "drizzle-orm";
import { database } from "../db/index.js";
import { checkins as checkinsTable, friendships as friendshipsTable } from "../db/schema.js";

type FriendshipRow = typeof friendshipsTable.$inferSelect;

/** How the signed-in user relates to someone else, from their side. */
export type FriendshipStatus = "none" | "friends" | "outgoingRequest" | "incomingRequest";

export interface FriendshipState {
  status: FriendshipStatus;
  /**
   * The pending request's id, so the client can accept, decline or cancel it.
   * A declined request keeps its id for the requester, who can still cancel.
   */
  friendRequestId: string | null;
}

const NO_FRIENDSHIP: FriendshipState = { status: "none", friendRequestId: null };

/**
 * A subquery of the user ids someone is friends with. A friendship is one row
 * whichever way the request went, so both directions are unioned.
 *
 * Written as raw SQL rather than a query builder so it stays a plain
 * expression: it never touches the database client until it is embedded in a
 * query that runs.
 */
export function friendIdsOf(userId: string): SQL {
  return sql`(
    select ${friendshipsTable.addresseeId} from ${friendshipsTable}
    where ${friendshipsTable.requesterId} = ${userId} and ${friendshipsTable.status} = 'accepted'
    union all
    select ${friendshipsTable.requesterId} from ${friendshipsTable}
    where ${friendshipsTable.addresseeId} = ${userId} and ${friendshipsTable.status} = 'accepted'
  )`;
}

/** Checkins by one of the user's friends. */
export function isFriendsCheckin(userId: string): SQL {
  return sql`${checkinsTable.userId} in ${friendIdsOf(userId)}`;
}

/**
 * Checkins the user is allowed to see: all of their own, and their friends'
 * friends-visible ones. Anyone else's are filtered out rather than refused, so a
 * request for a stranger's checkins, or for a friend's private one, looks the
 * same as one for a user with none.
 */
export function isVisibleCheckin(userId: string): SQL {
  return or(
    eq(checkinsTable.userId, userId),
    and(isFriendsCheckin(userId), eq(checkinsTable.visibility, "friends")),
  ) as SQL;
}

/** The row for the pair, in whichever direction it was created. */
export function isPairFriendship(firstUserId: string, secondUserId: string): SQL {
  return or(
    and(
      eq(friendshipsTable.requesterId, firstUserId),
      eq(friendshipsTable.addresseeId, secondUserId),
    ),
    and(
      eq(friendshipsTable.requesterId, secondUserId),
      eq(friendshipsTable.addresseeId, firstUserId),
    ),
  ) as SQL;
}

export function toFriendshipState(
  friendship: FriendshipRow | undefined,
  currentUserId: string,
): FriendshipState {
  if (!friendship) {
    return NO_FRIENDSHIP;
  }
  if (friendship.status === "accepted") {
    return { status: "friends", friendRequestId: null };
  }
  // The requester sees a declined request as still pending; the addressee
  // sees nothing, as if they had never been asked.
  if (friendship.status === "declined" && friendship.addresseeId === currentUserId) {
    return NO_FRIENDSHIP;
  }
  return {
    status: friendship.requesterId === currentUserId ? "outgoingRequest" : "incomingRequest",
    friendRequestId: friendship.id,
  };
}

/**
 * How the current user relates to each of `otherUserIds`, in one query.
 * Users with no row between them map to "none".
 */
export async function loadFriendshipStates(
  currentUserId: string,
  otherUserIds: string[],
): Promise<(otherUserId: string) => FriendshipState> {
  if (otherUserIds.length === 0) {
    return () => NO_FRIENDSHIP;
  }

  const rows = await database
    .select()
    .from(friendshipsTable)
    .where(
      or(
        and(
          eq(friendshipsTable.requesterId, currentUserId),
          inArray(friendshipsTable.addresseeId, otherUserIds),
        ),
        and(
          eq(friendshipsTable.addresseeId, currentUserId),
          inArray(friendshipsTable.requesterId, otherUserIds),
        ),
      ),
    );

  const rowsByOtherUserId = new Map(
    rows.map((row) => [
      row.requesterId === currentUserId ? row.addresseeId : row.requesterId,
      row,
    ]),
  );
  return (otherUserId) => toFriendshipState(rowsByOtherUserId.get(otherUserId), currentUserId);
}
