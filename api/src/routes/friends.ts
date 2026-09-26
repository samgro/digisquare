import { Hono } from "hono";
import { and, asc, desc, eq, inArray } from "drizzle-orm";
import { z } from "zod";
import { database } from "../db/index.js";
import {
  checkins as checkinsTable,
  friendships as friendshipsTable,
  notifications as notificationsTable,
  users as usersTable,
} from "../db/schema.js";
import { loadPhotosByCheckinId, toCheckinResult } from "../lib/checkin-result.js";
import { checkinSocialColumns } from "../lib/checkin-social.js";
import { isUniqueViolation } from "../lib/database-errors.js";
import { friendIdsOf, isPairFriendship, isVisibleCheckin } from "../lib/friendships.js";
import { createdBefore, paginationQuerySchema } from "../lib/pagination.js";
import { toPublicUserResult, toUserSummary } from "../lib/user-result.js";
import { requireAuth } from "../middleware/require-auth.js";
import type { AppEnv } from "../types.js";

const sendRequestSchema = z.object({
  userId: z.string().uuid(),
});

const idParamSchema = z.object({
  id: z.string().uuid(),
});

export const friends = new Hono<AppEnv>();

friends.use(requireAuth);

/** Tells the requester their request was accepted, and retires the request itself. */
async function notifyRequestAccepted(friendship: { id: string; requesterId: string; addresseeId: string }) {
  await database
    .delete(notificationsTable)
    .where(
      and(
        eq(notificationsTable.friendshipId, friendship.id),
        eq(notificationsTable.kind, "friend_request"),
      ),
    );
  await database.insert(notificationsTable).values({
    recipientId: friendship.requesterId,
    actorId: friendship.addresseeId,
    kind: "friend_accepted",
    friendshipId: friendship.id,
  });
}

friends.get("/", async (context) => {
  try {
    const rows = await database
      .select()
      .from(usersTable)
      .where(inArray(usersTable.id, friendIdsOf(context.get("userId"))))
      .orderBy(asc(usersTable.name));

    return context.json({ results: rows.map(toPublicUserResult) });
  } catch (error) {
    console.error(error);
    return context.json({ error: "Failed to fetch friends" }, 500);
  }
});

// Your friends' checkins and your own, so the feed reads as the whole group's
// activity and a checkin you just made shows up alongside theirs. Private
// checkins stay out, your own included: the feed is what the group shares.
friends.get("/checkins", async (context) => {
  const parsed = paginationQuerySchema.safeParse(context.req.query());
  if (!parsed.success) {
    return context.json(
      { error: "Invalid query parameters", details: parsed.error.flatten() },
      400,
    );
  }

  const currentUserId = context.get("userId");

  try {
    const rows = await database
      .select({ checkin: checkinsTable, user: usersTable, ...checkinSocialColumns(currentUserId) })
      .from(checkinsTable)
      .innerJoin(usersTable, eq(usersTable.id, checkinsTable.userId))
      .where(
        and(
          isVisibleCheckin(currentUserId),
          eq(checkinsTable.visibility, "friends"),
          createdBefore(checkinsTable.createdAt, parsed.data.before),
        ),
      )
      .orderBy(desc(checkinsTable.createdAt))
      .limit(parsed.data.limit);
    const photosByCheckinId = await loadPhotosByCheckinId(rows.map((row) => row.checkin.id));

    return context.json({
      results: rows.map((row) => ({
        ...toCheckinResult(row.checkin, row, photosByCheckinId.get(row.checkin.id)),
        user: toUserSummary(row.user),
      })),
    });
  } catch (error) {
    console.error(error);
    return context.json({ error: "Failed to fetch checkins" }, 500);
  }
});

// Incoming requests only. What you have sent shows up as "Requested" in
// search and on the person's profile instead.
friends.get("/requests", async (context) => {
  try {
    const rows = await database
      .select({ friendship: friendshipsTable, user: usersTable })
      .from(friendshipsTable)
      .innerJoin(usersTable, eq(usersTable.id, friendshipsTable.requesterId))
      .where(
        and(
          eq(friendshipsTable.addresseeId, context.get("userId")),
          eq(friendshipsTable.status, "pending"),
        ),
      )
      .orderBy(desc(friendshipsTable.createdAt));

    return context.json({
      results: rows.map((row) => ({
        id: row.friendship.id,
        user: toPublicUserResult(row.user),
        createdAt: row.friendship.createdAt,
      })),
    });
  } catch (error) {
    console.error(error);
    return context.json({ error: "Failed to fetch friend requests" }, 500);
  }
});

friends.post("/requests", async (context) => {
  let body: unknown;
  try {
    body = await context.req.json();
  } catch {
    return context.json({ error: "Invalid JSON body" }, 400);
  }

  const parsed = sendRequestSchema.safeParse(body);
  if (!parsed.success) {
    return context.json({ error: "Invalid friend request", details: parsed.error.flatten() }, 400);
  }

  const currentUserId = context.get("userId");
  const otherUserId = parsed.data.userId;
  if (otherUserId === currentUserId) {
    return context.json({ error: "You can't send a friend request to yourself" }, 400);
  }

  try {
    const [otherUser] = await database
      .select({ id: usersTable.id })
      .from(usersTable)
      .where(eq(usersTable.id, otherUserId));
    if (!otherUser) {
      return context.json({ error: "User not found" }, 404);
    }

    // They already asked you. Adding them back is an answer, not a second
    // request, and the pair index would reject a second row anyway. This
    // also takes back a request of theirs you declined earlier.
    const [accepted] = await database
      .update(friendshipsTable)
      .set({ status: "accepted" })
      .where(
        and(
          eq(friendshipsTable.requesterId, otherUserId),
          eq(friendshipsTable.addresseeId, currentUserId),
          inArray(friendshipsTable.status, ["pending", "declined"]),
        ),
      )
      .returning();
    if (accepted) {
      await notifyRequestAccepted(accepted);
      return context.json({ id: accepted.id, status: "accepted" });
    }

    const [created] = await database
      .insert(friendshipsTable)
      .values({ requesterId: currentUserId, addresseeId: otherUserId })
      .returning();

    // The request shows up in their bell. The partial unique index makes a
    // second insert for the same request a no-op.
    await database
      .insert(notificationsTable)
      .values({
        recipientId: otherUserId,
        actorId: currentUserId,
        kind: "friend_request",
        friendshipId: created.id,
      })
      .onConflictDoNothing();

    return context.json({ id: created.id, status: "pending" }, 201);
  } catch (error) {
    // Already friends, already requested, or they asked you in the moment
    // between the update above and this insert.
    if (isUniqueViolation(error)) {
      return context.json({ error: "Friend request already exists" }, 409);
    }
    console.error(error);
    return context.json({ error: "Failed to send friend request" }, 500);
  }
});

friends.post("/requests/:id/accept", async (context) => {
  const parsed = idParamSchema.safeParse({ id: context.req.param("id") });
  if (!parsed.success) {
    return context.json({ error: "Invalid friend request id" }, 400);
  }

  try {
    // Only the person who was asked can accept.
    const [accepted] = await database
      .update(friendshipsTable)
      .set({ status: "accepted" })
      .where(
        and(
          eq(friendshipsTable.id, parsed.data.id),
          eq(friendshipsTable.addresseeId, context.get("userId")),
          eq(friendshipsTable.status, "pending"),
        ),
      )
      .returning();

    if (!accepted) {
      return context.json({ error: "Friend request not found" }, 404);
    }

    await notifyRequestAccepted(accepted);
    return context.json({ id: accepted.id, status: "accepted" });
  } catch (error) {
    console.error(error);
    return context.json({ error: "Failed to accept friend request" }, 500);
  }
});

// Declines a request you received, or cancels one you sent. Declining keeps
// the row as "declined" so the requester still sees it as pending; cancelling
// deletes it, whether or not it was declined, and its notification goes with
// it through the foreign key.
friends.delete("/requests/:id", async (context) => {
  const parsed = idParamSchema.safeParse({ id: context.req.param("id") });
  if (!parsed.success) {
    return context.json({ error: "Invalid friend request id" }, 400);
  }

  const currentUserId = context.get("userId");

  try {
    const [declined] = await database
      .update(friendshipsTable)
      .set({ status: "declined" })
      .where(
        and(
          eq(friendshipsTable.id, parsed.data.id),
          eq(friendshipsTable.addresseeId, currentUserId),
          eq(friendshipsTable.status, "pending"),
        ),
      )
      .returning({ id: friendshipsTable.id });
    if (declined) {
      // Nothing left to act on in the bell. The row itself stays, so the
      // requester is none the wiser.
      await database
        .delete(notificationsTable)
        .where(
          and(
            eq(notificationsTable.friendshipId, declined.id),
            eq(notificationsTable.kind, "friend_request"),
          ),
        );
      return context.body(null, 204);
    }

    const [cancelled] = await database
      .delete(friendshipsTable)
      .where(
        and(
          eq(friendshipsTable.id, parsed.data.id),
          eq(friendshipsTable.requesterId, currentUserId),
          inArray(friendshipsTable.status, ["pending", "declined"]),
        ),
      )
      .returning({ id: friendshipsTable.id });

    if (!cancelled) {
      return context.json({ error: "Friend request not found" }, 404);
    }

    return context.body(null, 204);
  } catch (error) {
    console.error(error);
    return context.json({ error: "Failed to delete friend request" }, 500);
  }
});

// Registered after the /requests and /checkins routes so those literal paths
// are never read as a user id.
friends.delete("/:id", async (context) => {
  const parsed = idParamSchema.safeParse({ id: context.req.param("id") });
  if (!parsed.success) {
    return context.json({ error: "Invalid user id" }, 400);
  }

  try {
    const [deleted] = await database
      .delete(friendshipsTable)
      .where(
        and(
          isPairFriendship(context.get("userId"), parsed.data.id),
          eq(friendshipsTable.status, "accepted"),
        ),
      )
      .returning({ id: friendshipsTable.id });

    if (!deleted) {
      return context.json({ error: "Friend not found" }, 404);
    }

    return context.body(null, 204);
  } catch (error) {
    console.error(error);
    return context.json({ error: "Failed to remove friend" }, 500);
  }
});
