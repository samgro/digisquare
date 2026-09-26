import { randomUUID } from "node:crypto";
import { Hono } from "hono";
import { and, asc, desc, eq, or, sql } from "drizzle-orm";
import { z } from "zod";
import { database } from "../db/index.js";
import {
  CHECKIN_SOURCES,
  CHECKIN_VISIBILITIES,
  checkinComments as checkinCommentsTable,
  checkinLikes as checkinLikesTable,
  checkinPhotos as checkinPhotosTable,
  checkins as checkinsTable,
  notifications as notificationsTable,
  users as usersTable,
} from "../db/schema.js";
import {
  loadPhotosByCheckinId,
  toCheckinPhotoResult,
  toCheckinResult,
} from "../lib/checkin-result.js";
import {
  checkinSocialColumns,
  findVisibleCheckin,
  loadCheckinSocial,
  toCommentResult,
} from "../lib/checkin-social.js";
import { formatAddress } from "../lib/place-result.js";
import { findPlaceById } from "../lib/places-search.js";
import { isVisibleCheckin } from "../lib/friendships.js";
import { createdBefore, paginationQuerySchema } from "../lib/pagination.js";
import { IMAGE_MAX_BYTES, createImageUploadUrl, isOwnedImageKey } from "../lib/r2.js";
import {
  CURSOR_TIMESTAMP_FORMAT,
  ZERO_UUID,
  decodeSyncCursor,
  encodeSyncCursor,
  type SyncCursor,
} from "../lib/sync-cursor.js";
import { requireAuth } from "../middleware/require-auth.js";
import type { AppEnv } from "../types.js";

/** How far ahead of the server clock a client-supplied `createdAt` may be. */
const MAXIMUM_CREATED_AT_SKEW_MILLISECONDS = 5 * 60 * 1000;

const MAX_PHOTOS_PER_CHECKIN = 4;

const createdAtSchema = z
  .string()
  .datetime({ offset: true })
  .transform((value) => new Date(value))
  .refine((date) => date.getTime() <= Date.now() + MAXIMUM_CREATED_AT_SKEW_MILLISECONDS, {
    message: "createdAt must not be in the future",
  });

// No userId here on purpose: identity comes from the access token. Nor any
// place details: the server snapshots them from the `places` row, so a
// client cannot file a checkin at one place under another's name. The schema
// is left non-strict so an older client still sending those is simply
// ignored rather than rejected with a 400 it cannot act on.
const createCheckinSchema = z.object({
  placeId: z.string().uuid(),
  message: z.string().trim().min(1).max(2000).nullable().optional(),
  visibility: z.enum(CHECKIN_VISIBILITIES).default("friends"),
  source: z.enum(CHECKIN_SOURCES).default("manual"),
  // A checkin accepted from a detected visit is backdated to when the visit
  // started, so the timeline shows when the user was there rather than when
  // they tapped Accept.
  createdAt: createdAtSchema.optional(),
  // Minutes east of UTC where the checkin happened, e.g. -420 in California.
  timeZoneOffsetMinutes: z.number().int().min(-720).max(840).nullable().optional(),
  // Keys from POST /checkins/photo-uploads, already uploaded, in display order.
  photos: z
    .array(
      z.object({
        key: z.string().min(1),
        width: z.number().int().positive().nullable().optional(),
        height: z.number().int().positive().nullable().optional(),
      }),
    )
    .max(MAX_PHOTOS_PER_CHECKIN)
    .optional(),
});

const photoUploadSchema = z.object({
  contentType: z.literal("image/jpeg"),
  contentLength: z.number().int().positive().max(IMAGE_MAX_BYTES),
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
  placeId: z.string().uuid().optional(),
});

const commentsQuerySchema = paginationQuerySchema.extend({
  limit: z.coerce.number().int().positive().max(100).default(50),
});

const syncQuerySchema = z.object({
  cursor: z.string().min(1).optional(),
  limit: z.coerce.number().int().positive().max(500).default(200),
});

// The changes phase never returns rows younger than this. A row's updated_at
// is stamped before its transaction commits, so without the window the cursor
// could move past a timestamp whose row is not visible yet, and that row would
// never be synced. It also absorbs small skew between the API's clock (which
// stamps updates via $onUpdate) and the database's (which stamps inserts).
const SETTLE_WINDOW = sql`interval '5 seconds'`;
// How far before the first backfill request the changes phase starts. Rows
// edited in that overlap come down twice, which is harmless: clients upsert.
const BACKFILL_OVERLAP = sql`interval '1 minute'`;

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

  const userId = context.get("userId");
  const photos = parsed.data.photos ?? [];
  // Photo keys are minted per user, so anything else is someone else's image
  // or a made-up key, and attaching it would publish it under this checkin.
  if (photos.some((photo) => !isOwnedImageKey("checkin-photos", photo.key, userId))) {
    return context.json({ error: "Invalid photo key" }, 400);
  }

  try {
    // Looked up as the caller, so a stranger's private venue and a place
    // Overture has since dropped are both "not found".
    const place = await findPlaceById(parsed.data.placeId, userId);
    if (!place || place.retiredAt !== null) {
      return context.json({ error: "Place not found" }, 404);
    }

    // Generated here rather than by Postgres so the photo rows can reference
    // it in the same batch; a batched insert cannot feed its id to the next.
    const checkinId = randomUUID();
    const insertCheckin = database
      .insert(checkinsTable)
      .values({
        id: checkinId,
        userId,
        placeId: place.id,
        placeName: place.name,
        placeAddress: formatAddress(place),
        placeLocality: place.addressLocality,
        placeRegion: place.addressRegion,
        placeCountry: place.addressCountry,
        placePrimaryType: place.primaryType,
        placeTypes: place.types,
        placeCategoryName: place.categoryName,
        latitude: place.latitude,
        longitude: place.longitude,
        message: parsed.data.message ?? null,
        visibility: parsed.data.visibility,
        source: parsed.data.source,
        timeZoneOffsetMinutes: parsed.data.timeZoneOffsetMinutes ?? null,
        ...(parsed.data.createdAt === undefined ? {} : { createdAt: parsed.data.createdAt }),
      })
      .returning();

    // Nobody has had a chance to like it yet, so the counts are zero.
    if (photos.length === 0) {
      const [created] = await insertCheckin;
      return context.json(toCheckinResult(created!), 201);
    }

    // One batch, so a checkin never lands without the photos it was sent with.
    const [createdCheckins, createdPhotos] = await database.batch([
      insertCheckin,
      database
        .insert(checkinPhotosTable)
        .values(
          photos.map((photo, position) => ({
            checkinId,
            position,
            storageKey: photo.key,
            width: photo.width ?? null,
            height: photo.height ?? null,
          })),
        )
        .returning(),
    ]);

    return context.json(
      toCheckinResult(createdCheckins[0]!, undefined, createdPhotos.map(toCheckinPhotoResult)),
      201,
    );
  } catch (error) {
    console.error(error);
    return context.json({ error: "Failed to create checkin" }, 500);
  }
});

// A presigned URL to PUT one photo to before creating the checkin it belongs
// to; the key comes back in that request's `photos`.
checkins.post("/photo-uploads", async (context) => {
  let body: unknown;
  try {
    body = await context.req.json();
  } catch {
    return context.json({ error: "Invalid JSON body" }, 400);
  }

  const parsed = photoUploadSchema.safeParse(body);
  if (!parsed.success) {
    return context.json({ error: "Invalid upload request", details: parsed.error.flatten() }, 400);
  }

  try {
    const upload = await createImageUploadUrl(
      "checkin-photos",
      context.get("userId"),
      parsed.data.contentLength,
    );
    return context.json(upload);
  } catch (error) {
    console.error(error);
    return context.json({ error: "Failed to create upload url" }, 500);
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
  const { userId, placeId, limit, before } = parsed.data;
  const conditions = [
    // Only your own checkins and your friends' non-private ones. A stranger's
    // userId is filtered to an empty list rather than refused, so the response
    // does not confirm the user exists.
    isVisibleCheckin(currentUserId),
    userId ? eq(checkinsTable.userId, userId) : undefined,
    placeId ? eq(checkinsTable.placeId, placeId) : undefined,
    createdBefore(checkinsTable.createdAt, before),
  ].filter((condition) => condition !== undefined);

  try {
    const rows = await database
      .select({ checkin: checkinsTable, ...checkinSocialColumns(currentUserId) })
      .from(checkinsTable)
      .where(and(...conditions))
      .orderBy(desc(checkinsTable.createdAt))
      .limit(limit);
    const photosByCheckinId = await loadPhotosByCheckinId(rows.map((row) => row.checkin.id));

    return context.json({
      results: rows.map((row) =>
        toCheckinResult(row.checkin, row, photosByCheckinId.get(row.checkin.id)),
      ),
    });
  } catch (error) {
    console.error(error);
    return context.json({ error: "Failed to fetch checkins" }, 500);
  }
});

/**
 * Pages through every checkin the caller owns so a client can keep a complete
 * local copy. Clients loop while `hasMore`, persisting `nextCursor` after each
 * page, and keep the last cursor to pick up later changes.
 *
 * A like, comment or photo change bumps its checkin's updated_at (a
 * trigger), so the changes phase carries fresh counts and photo urls as well
 * as edits.
 *
 * Registered before /:id, which would otherwise reject "sync" as an invalid
 * uuid.
 */
checkins.get("/sync", async (context) => {
  const parsed = syncQuerySchema.safeParse(context.req.query());
  if (!parsed.success) {
    return context.json(
      { error: "Invalid query parameters", details: parsed.error.flatten() },
      400,
    );
  }

  let cursor: SyncCursor | null = null;
  if (parsed.data.cursor !== undefined) {
    cursor = decodeSyncCursor(parsed.data.cursor);
    if (!cursor) {
      // Clients treat this as "start over", so it must stay a 400 rather than
      // falling back to a first page the client would mistake for a resume.
      return context.json({ error: "Invalid sync cursor" }, 400);
    }
  }

  const currentUserId = context.get("userId");
  const { limit } = parsed.data;
  const ownedByCaller = eq(checkinsTable.userId, currentUserId);

  try {
    // An aggregate always yields exactly one row, even for a user with no
    // checkins, so `since` is available for the very first request too.
    const [summary] = await database
      .select({
        totalCount: sql<number>`count(*)::int`,
        since: sql<string>`to_char((now() - ${BACKFILL_OVERLAP}) at time zone 'UTC', ${CURSOR_TIMESTAMP_FORMAT})`,
      })
      .from(checkinsTable)
      .where(ownedByCaller);

    const pageColumns = {
      checkin: checkinsTable,
      ...checkinSocialColumns(currentUserId),
      createdAtKey: sql<string>`to_char(${checkinsTable.createdAt} at time zone 'UTC', ${CURSOR_TIMESTAMP_FORMAT})`,
      updatedAtKey: sql<string>`to_char(${checkinsTable.updatedAt} at time zone 'UTC', ${CURSOR_TIMESTAMP_FORMAT})`,
    };

    if (cursor === null || cursor.phase === "backfill") {
      const since = cursor?.since ?? summary.since;
      const rows = await database
        .select(pageColumns)
        .from(checkinsTable)
        .where(
          cursor
            ? and(
                ownedByCaller,
                sql`(${checkinsTable.createdAt}, ${checkinsTable.id}) < (${cursor.createdAt}::timestamptz, ${cursor.id}::uuid)`,
              )
            : ownedByCaller,
        )
        .orderBy(desc(checkinsTable.createdAt), desc(checkinsTable.id))
        .limit(limit);

      const lastRow = rows.at(-1);
      // A short page means the history is exhausted. Hand over to the
      // changes phase, which still has to run once to catch anything created
      // or edited while the backfill was paging — so hasMore stays true.
      const nextCursor: SyncCursor =
        rows.length === limit && lastRow
          ? { phase: "backfill", createdAt: lastRow.createdAtKey, id: lastRow.checkin.id, since }
          : { phase: "changes", updatedAt: since, id: ZERO_UUID };

      const photosByCheckinId = await loadPhotosByCheckinId(rows.map((row) => row.checkin.id));
      return context.json({
        results: rows.map((row) =>
          toCheckinResult(row.checkin, row, photosByCheckinId.get(row.checkin.id)),
        ),
        nextCursor: encodeSyncCursor(nextCursor),
        hasMore: true,
        totalCount: summary.totalCount,
      });
    }

    const rows = await database
      .select(pageColumns)
      .from(checkinsTable)
      .where(
        and(
          ownedByCaller,
          sql`(${checkinsTable.updatedAt}, ${checkinsTable.id}) > (${cursor.updatedAt}::timestamptz, ${cursor.id}::uuid)`,
          sql`${checkinsTable.updatedAt} < now() - ${SETTLE_WINDOW}`,
        ),
      )
      .orderBy(asc(checkinsTable.updatedAt), asc(checkinsTable.id))
      .limit(limit);

    const lastRow = rows.at(-1);
    const nextCursor: SyncCursor = lastRow
      ? { phase: "changes", updatedAt: lastRow.updatedAtKey, id: lastRow.checkin.id }
      : cursor;

    const photosByCheckinId = await loadPhotosByCheckinId(rows.map((row) => row.checkin.id));
    return context.json({
      results: rows.map((row) =>
        toCheckinResult(row.checkin, row, photosByCheckinId.get(row.checkin.id)),
      ),
      nextCursor: encodeSyncCursor(nextCursor),
      hasMore: rows.length === limit,
      totalCount: summary.totalCount,
    });
  } catch (error) {
    console.error(error);
    return context.json({ error: "Failed to sync checkins" }, 500);
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

    const photosByCheckinId = await loadPhotosByCheckinId([row.checkin.id]);
    return context.json(toCheckinResult(row.checkin, row, photosByCheckinId.get(row.checkin.id)));
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
    const photosByCheckinId = await loadPhotosByCheckinId([updated.id]);
    return context.json(toCheckinResult(updated, social, photosByCheckinId.get(updated.id)));
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
