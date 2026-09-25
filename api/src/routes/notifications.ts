import { Hono } from "hono";
import { and, count, desc, eq, isNull } from "drizzle-orm";
import { database } from "../db/index.js";
import {
  checkinComments as checkinCommentsTable,
  checkins as checkinsTable,
  friendships as friendshipsTable,
  notifications as notificationsTable,
  users as usersTable,
} from "../db/schema.js";
import { createdBefore, paginationQuerySchema } from "../lib/pagination.js";
import { toUserSummary } from "../lib/user-result.js";
import { requireAuth } from "../middleware/require-auth.js";
import type { AppEnv } from "../types.js";

const listQuerySchema = paginationQuerySchema.extend({
  limit: paginationQuerySchema.shape.limit.default(30),
});

export const notifications = new Hono<AppEnv>();

notifications.use(requireAuth);

async function countUnread(recipientId: string): Promise<number> {
  const [row] = await database
    .select({ value: count() })
    .from(notificationsTable)
    .where(and(eq(notificationsTable.recipientId, recipientId), isNull(notificationsTable.readAt)));
  return row?.value ?? 0;
}

// The bell feed: newest first, each row carrying just enough of its subject
// to draw one line ("Alex liked your checkin at Blue Bottle") and to act on
// it (the friendship's status says whether Accept/Decline still apply).
notifications.get("/", async (context) => {
  const parsed = listQuerySchema.safeParse(context.req.query());
  if (!parsed.success) {
    return context.json(
      { error: "Invalid query parameters", details: parsed.error.flatten() },
      400,
    );
  }

  const currentUserId = context.get("userId");

  try {
    const rows = await database
      .select({
        notification: notificationsTable,
        actor: usersTable,
        checkin: { id: checkinsTable.id, placeName: checkinsTable.placeName },
        comment: { id: checkinCommentsTable.id, body: checkinCommentsTable.body },
        friendship: { id: friendshipsTable.id, status: friendshipsTable.status },
      })
      .from(notificationsTable)
      .innerJoin(usersTable, eq(usersTable.id, notificationsTable.actorId))
      .leftJoin(checkinsTable, eq(checkinsTable.id, notificationsTable.checkinId))
      .leftJoin(checkinCommentsTable, eq(checkinCommentsTable.id, notificationsTable.commentId))
      .leftJoin(friendshipsTable, eq(friendshipsTable.id, notificationsTable.friendshipId))
      .where(
        and(
          eq(notificationsTable.recipientId, currentUserId),
          createdBefore(notificationsTable.createdAt, parsed.data.before),
        ),
      )
      .orderBy(desc(notificationsTable.createdAt))
      .limit(parsed.data.limit);

    const unreadCount = await countUnread(currentUserId);

    return context.json({
      results: rows.map((row) => ({
        id: row.notification.id,
        kind: row.notification.kind,
        actor: toUserSummary(row.actor),
        checkin: row.checkin,
        comment: row.comment,
        friendship: row.friendship,
        readAt: row.notification.readAt,
        createdAt: row.notification.createdAt,
      })),
      unreadCount,
    });
  } catch (error) {
    console.error(error);
    return context.json({ error: "Failed to fetch notifications" }, 500);
  }
});

// For the badge: cheap enough to ask on every return to the foreground.
notifications.get("/unread-count", async (context) => {
  try {
    return context.json({ unreadCount: await countUnread(context.get("userId")) });
  } catch (error) {
    console.error(error);
    return context.json({ error: "Failed to count notifications" }, 500);
  }
});

// Opening the feed reads everything, the way a bell badge clears on a
// glance rather than one row at a time.
notifications.post("/read", async (context) => {
  try {
    await database
      .update(notificationsTable)
      .set({ readAt: new Date() })
      .where(
        and(
          eq(notificationsTable.recipientId, context.get("userId")),
          isNull(notificationsTable.readAt),
        ),
      );

    return context.body(null, 204);
  } catch (error) {
    console.error(error);
    return context.json({ error: "Failed to mark notifications read" }, 500);
  }
});
