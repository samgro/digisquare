import { Hono } from "hono";
import { and, desc, eq, or, sql } from "drizzle-orm";
import { z } from "zod";
import { database } from "../db/index.js";
import {
  CHECKIN_SOURCES,
  CHECKIN_VISIBILITIES,
  checkinComments as checkinCommentsTable,
  checkinLikes as checkinLikesTable,
  checkins as checkinsTable,
  notifications as notificationsTable,
  users as usersTable,
} from "../db/schema.js";
import { toCheckinResult } from "../lib/checkin-result.js";
import {
  checkinSocialColumns,
  findVisibleCheckin,
  loadCheckinSocial,
  toCommentResult,
} from "../lib/checkin-social.js";
import { isVisibleCheckin } from "../lib/friendships.js";
import { createdBefore, paginationQuerySchema } from "../lib/pagination.js";
import { requireAuth } from "../middleware/require-auth.js";
import type { AppEnv } from "../types.js";

/** How far ahead of the server clock a client-supplied `createdAt` may be. */
const MAXIMUM_CREATED_AT_SKEW_MILLISECONDS = 5 * 60 * 1000;

const createdAtSchema = z
  .string()
  .datetime({ offset: true })
  .transform((value) => new Date(value))
  .refine((date) => date.getTime() <= Date.now() + MAXIMUM_CREATED_AT_SKEW_MILLISECONDS, {
    message: "createdAt must not be in the future",
  });

// No userId here on purpose: identity comes from the access token. The
// schema is left non-strict so an older client still sending one is simply
// ignored rather than rejected with a 400 it cannot act on.
const createCheckinSchema = z.object({
  googlePlaceId: z.string().trim().min(1),
  placeName: z.string().trim().min(1),
  placeAddress: z.string().trim().min(1).nullable().optional(),
  placePrimaryType: z.string().trim().min(1).nullable().optional(),
  placeTypes: z.array(z.string().trim().min(1)).nullable().optional(),
  latitude: z.number().min(-90).max(90).nullable().optional(),
  longitude: z.number().min(-180).max(180).nullable().optional(),
  message: z.string().trim().min(1).max(2000).nullable().optional(),
  visibility: z.enum(CHECKIN_VISIBILITIES).default("friends"),
  source: z.enum(CHECKIN_SOURCES).default("manual"),
  // A checkin accepted from a detected visit is backdated to when the visit
  // started, so the timeline shows when the user was there rather than when
  // they tapped Accept.
  createdAt: createdAtSchema.optional(),
});

// The venue is fixed once checked in; only what you said and who sees it
// can change.
const updateCheckinSchema = z
  .object({
    message: z.string().trim().min(1).max(2000).nullable(),
    visibility: z.enum(CHECKIN_VISIBILITIES),
  })
  .partial()
  .refine((data) => Object.keys(data).length > 0, {
    message: "At least one field must be provided",
  });

const idParamSchema = z.object({
  id: z.string().uuid(),
});

const commentParamsSchema = z.object({
  id: z.string().uuid(),
  commentId: z.string().uuid(),
});

const listQuerySchema = paginationQuerySchema.extend({
  userId: z.string().uuid().optional(),
  googlePlaceId: z.string().trim().min(1).optional(),
});

const commentsQuerySchema = paginationQuerySchema.extend({
  limit: z.coerce.number().int().positive().max(100).default(50),
});

const createCommentSchema = z.object({
  body: z.string().trim().min(1).max(1000),
});

export const checkins = new Hono<AppEnv>();

checkins.use(requireAuth);

checkins.post("/", async (context) => {
  let body: unknown;
  try {
    body = await context.req.json();
  } catch {
    return context.json({ error: "Invalid JSON body" }, 400);
  }

  const parsed = createCheckinSchema.safeParse(body);
  if (!parsed.success) {
    return context.json({ error: "Invalid checkin", details: parsed.error.flatten() }, 400);
  }

  try {
    const [created] = await database
      .insert(checkinsTable)
      .values({
        userId: context.get("userId"),
        googlePlaceId: parsed.data.googlePlaceId,
        placeName: parsed.data.placeName,
        placeAddress: parsed.data.placeAddress ?? null,
        placePrimaryType: parsed.data.placePrimaryType ?? null,
        placeTypes: parsed.data.placeTypes ?? null,
        latitude: parsed.data.latitude ?? null,
        longitude: parsed.data.longitude ?? null,
        message: parsed.data.message ?? null,
        visibility: parsed.data.visibility,
        source: parsed.data.source,
        ...(parsed.data.createdAt === undefined ? {} : { createdAt: parsed.data.createdAt }),
      })
      .returning();

    // Nobody has had a chance to like it yet, so the counts are zero.
    return context.json(toCheckinResult(created), 201);
  } catch (error) {
    console.error(error);
    return context.json({ error: "Failed to create checkin" }, 500);
  }
});

checkins.get("/", async (context) => {
  const parsed = listQuerySchema.safeParse(context.req.query());
  if (!parsed.success) {
    return context.json(
      { error: "Invalid query parameters", details: parsed.error.flatten() },
      400,
    );
  }

  const currentUserId = context.get("userId");
  const { userId, googlePlaceId, limit, before } = parsed.data;
  const conditions = [
    // Only your own checkins and your friends' non-private ones. A stranger's
    // userId is filtered to an empty list rather than refused, so the response
    // does not confirm the user exists.
    isVisibleCheckin(currentUserId),
    userId ? eq(checkinsTable.userId, userId) : undefined,
    googlePlaceId ? eq(checkinsTable.googlePlaceId, googlePlaceId) : undefined,
    createdBefore(checkinsTable.createdAt, before),
  ].filter((condition) => condition !== undefined);

  try {
    const rows = await database
      .select({ checkin: checkinsTable, ...checkinSocialColumns(currentUserId) })
      .from(checkinsTable)
      .where(and(...conditions))
      .orderBy(desc(checkinsTable.createdAt))
      .limit(limit);

    return context.json({ results: rows.map((row) => toCheckinResult(row.checkin, row)) });
  } catch (error) {
    console.error(error);
    return context.json({ error: "Failed to fetch checkins" }, 500);
  }
});

checkins.get("/:id", async (context) => {
  const parsed = idParamSchema.safeParse({ id: context.req.param("id") });
  if (!parsed.success) {
    return context.json({ error: "Invalid checkin id" }, 400);
  }

  const currentUserId = context.get("userId");

  try {
    const [row] = await database
      .select({ checkin: checkinsTable, ...checkinSocialColumns(currentUserId) })
      .from(checkinsTable)
      .where(and(eq(checkinsTable.id, parsed.data.id), isVisibleCheckin(currentUserId)));

    // A stranger's checkin is the same 404 as one that does not exist.
    if (!row) {
      return context.json({ error: "Checkin not found" }, 404);
    }

    return context.json(toCheckinResult(row.checkin, row));
  } catch (error) {
    console.error(error);
    return context.json({ error: "Failed to fetch checkin" }, 500);
  }
});

checkins.patch("/:id", async (context) => {
  const paramsParsed = idParamSchema.safeParse({ id: context.req.param("id") });
  if (!paramsParsed.success) {
    return context.json({ error: "Invalid checkin id" }, 400);
  }

  let body: unknown;
  try {
    body = await context.req.json();
  } catch {
    return context.json({ error: "Invalid JSON body" }, 400);
  }

  const bodyParsed = updateCheckinSchema.safeParse(body);
  if (!bodyParsed.success) {
    return context.json(
      { error: "Invalid checkin update", details: bodyParsed.error.flatten() },
      400,
    );
  }

  const currentUserId = context.get("userId");

  try {
    // Scoping the update by owner means a checkin that exists but belongs to
    // someone else falls through to the same 404 as one that does not exist.
    // A 403 would confirm the id is real.
    const [updated] = await database
      .update(checkinsTable)
      .set(bodyParsed.data)
      .where(and(eq(checkinsTable.id, paramsParsed.data.id), eq(checkinsTable.userId, currentUserId)))
      .returning();

    if (!updated) {
      return context.json({ error: "Checkin not found" }, 404);
    }

    const social = await loadCheckinSocial(updated.id, currentUserId);
    return context.json(toCheckinResult(updated, social));
  } catch (error) {
    console.error(error);
    return context.json({ error: "Failed to update checkin" }, 500);
  }
});

// MARK: Likes

// Liking is idempotent: the second tap is a 200 that changes nothing, which
// is also what settles two taps racing each other, via the unique index.
checkins.post("/:id/likes", async (context) => {
  const parsed = idParamSchema.safeParse({ id: context.req.param("id") });
  if (!parsed.success) {
    return context.json({ error: "Invalid checkin id" }, 400);
  }

  const currentUserId = context.get("userId");

  try {
    const checkin = await findVisibleCheckin(parsed.data.id, currentUserId);
    if (!checkin) {
      return context.json({ error: "Checkin not found" }, 404);
    }

    const [inserted] = await database
      .insert(checkinLikesTable)
      .values({ checkinId: checkin.id, userId: currentUserId })
      .onConflictDoNothing()
      .returning({ id: checkinLikesTable.id });

    // Liking your own checkin is allowed but not news.
    if (inserted && checkin.userId !== currentUserId) {
      await database
        .insert(notificationsTable)
        .values({
          recipientId: checkin.userId,
          actorId: currentUserId,
          kind: "like",
          checkinId: checkin.id,
        })
        .onConflictDoNothing();
    }

    const social = await loadCheckinSocial(checkin.id, currentUserId);
    return context.json({ likeCount: social?.likeCount ?? 0, likedByMe: true });
  } catch (error) {
    console.error(error);
    return context.json({ error: "Failed to like checkin" }, 500);
  }
});

// The like notification stays: an unlike is not news, and if they like it
// again the unique index keeps the owner from being badged twice.
checkins.delete("/:id/likes", async (context) => {
  const parsed = idParamSchema.safeParse({ id: context.req.param("id") });
  if (!parsed.success) {
    return context.json({ error: "Invalid checkin id" }, 400);
  }

  const currentUserId = context.get("userId");

  try {
    const checkin = await findVisibleCheckin(parsed.data.id, currentUserId);
    if (!checkin) {
      return context.json({ error: "Checkin not found" }, 404);
    }

    await database
      .delete(checkinLikesTable)
      .where(
        and(eq(checkinLikesTable.checkinId, checkin.id), eq(checkinLikesTable.userId, currentUserId)),
      );

    const social = await loadCheckinSocial(checkin.id, currentUserId);
    return context.json({ likeCount: social?.likeCount ?? 0, likedByMe: false });
  } catch (error) {
    console.error(error);
    return context.json({ error: "Failed to unlike checkin" }, 500);
  }
});

// MARK: Comments

// Newest first like every other list here; the client shows the page the
// other way up so a thread reads top to bottom.
checkins.get("/:id/comments", async (context) => {
  const paramsParsed = idParamSchema.safeParse({ id: context.req.param("id") });
  if (!paramsParsed.success) {
    return context.json({ error: "Invalid checkin id" }, 400);
  }

  const queryParsed = commentsQuerySchema.safeParse(context.req.query());
  if (!queryParsed.success) {
    return context.json(
      { error: "Invalid query parameters", details: queryParsed.error.flatten() },
      400,
    );
  }

  const currentUserId = context.get("userId");

  try {
    const checkin = await findVisibleCheckin(paramsParsed.data.id, currentUserId);
    if (!checkin) {
      return context.json({ error: "Checkin not found" }, 404);
    }

    const conditions = [
      eq(checkinCommentsTable.checkinId, checkin.id),
      createdBefore(checkinCommentsTable.createdAt, queryParsed.data.before),
    ].filter((condition) => condition !== undefined);

    const rows = await database
      .select({ comment: checkinCommentsTable, user: usersTable })
      .from(checkinCommentsTable)
      .innerJoin(usersTable, eq(usersTable.id, checkinCommentsTable.userId))
      .where(and(...conditions))
      .orderBy(desc(checkinCommentsTable.createdAt))
      .limit(queryParsed.data.limit);

    return context.json({ results: rows.map((row) => toCommentResult(row.comment, row.user)) });
  } catch (error) {
    console.error(error);
    return context.json({ error: "Failed to fetch comments" }, 500);
  }
});

checkins.post("/:id/comments", async (context) => {
  const paramsParsed = idParamSchema.safeParse({ id: context.req.param("id") });
  if (!paramsParsed.success) {
    return context.json({ error: "Invalid checkin id" }, 400);
  }

  let body: unknown;
  try {
    body = await context.req.json();
  } catch {
    return context.json({ error: "Invalid JSON body" }, 400);
  }

  const bodyParsed = createCommentSchema.safeParse(body);
  if (!bodyParsed.success) {
    return context.json({ error: "Invalid comment", details: bodyParsed.error.flatten() }, 400);
  }

  const currentUserId = context.get("userId");

  try {
    const checkin = await findVisibleCheckin(paramsParsed.data.id, currentUserId);
    if (!checkin) {
      return context.json({ error: "Checkin not found" }, 404);
    }

    const [comment] = await database
      .insert(checkinCommentsTable)
      .values({ checkinId: checkin.id, userId: currentUserId, body: bodyParsed.data.body })
      .returning();

    // Every comment is news to the owner, unless they wrote it.
    if (checkin.userId !== currentUserId) {
      await database.insert(notificationsTable).values({
        recipientId: checkin.userId,
        actorId: currentUserId,
        kind: "comment",
        checkinId: checkin.id,
        commentId: comment.id,
      });
    }

    const [author] = await database
      .select()
      .from(usersTable)
      .where(eq(usersTable.id, currentUserId));

    return context.json(toCommentResult(comment, author), 201);
  } catch (error) {
    console.error(error);
    return context.json({ error: "Failed to add comment" }, 500);
  }
});

// Yours to delete if you wrote it or if it is on your checkin, the way a
// host can clear a comment from their own post. Anyone else's attempt is
// the same 404 as a comment that does not exist.
checkins.delete("/:id/comments/:commentId", async (context) => {
  const parsed = commentParamsSchema.safeParse({
    id: context.req.param("id"),
    commentId: context.req.param("commentId"),
  });
  if (!parsed.success) {
    return context.json({ error: "Invalid comment id" }, 400);
  }

  const currentUserId = context.get("userId");
  // Drizzle's delete has no join, so ownership of the checkin is a subquery.
  const ownsCheckin = sql`exists (
    select 1 from ${checkinsTable}
    where ${checkinsTable.id} = ${checkinCommentsTable.checkinId}
    and ${checkinsTable.userId} = ${currentUserId}
  )`;

  try {
    const [deleted] = await database
      .delete(checkinCommentsTable)
      .where(
        and(
          eq(checkinCommentsTable.id, parsed.data.commentId),
          eq(checkinCommentsTable.checkinId, parsed.data.id),
          or(eq(checkinCommentsTable.userId, currentUserId), ownsCheckin),
        ),
      )
      .returning({ id: checkinCommentsTable.id });

    if (!deleted) {
      return context.json({ error: "Comment not found" }, 404);
    }

    return context.body(null, 204);
  } catch (error) {
    console.error(error);
    return context.json({ error: "Failed to delete comment" }, 500);
  }
});
