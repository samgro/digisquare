import { Hono } from "hono";
import { and, asc, count, eq, ilike, isNotNull, ne, or } from "drizzle-orm";
import { z } from "zod";
import { database } from "../db/index.js";
import {
  checkins as checkinsTable,
  friendships as friendshipsTable,
  users as usersTable,
} from "../db/schema.js";
import { loadFriendshipStates } from "../lib/friendships.js";
import { AVATAR_MAX_BYTES, createAvatarUploadUrl, isOwnedAvatarKey } from "../lib/r2.js";
import { toPrivateUserResult, toPublicUserResult } from "../lib/user-result.js";
import { requireAuth } from "../middleware/require-auth.js";
import type { AppEnv } from "../types.js";

const updateProfileSchema = z
  .object({
    name: z.string().trim().min(1).max(60).nullable(),
    // Matches the 160-character counter in EditProfileView, so the limit is
    // something the user sees rather than discovers by being rejected.
    bio: z.string().trim().max(160).nullable(),
    avatarKey: z.string().trim().max(200).nullable(),
  })
  .partial()
  .refine((data) => Object.keys(data).length > 0, {
    message: "At least one field must be provided",
  });

const avatarUploadSchema = z.object({
  contentType: z.literal("image/jpeg"),
  contentLength: z.number().int().positive().max(AVATAR_MAX_BYTES),
});

const idParamSchema = z.object({
  id: z.string().uuid(),
});

// `q` is the one abbreviation CLAUDE.md allows, as a query parameter.
const searchQuerySchema = z.object({
  q: z.string().trim().min(1).max(60),
});

const SEARCH_RESULT_LIMIT = 20;

/**
 * Escapes LIKE's wildcards so a name containing % or _ is matched literally,
 * using backslash, Postgres's default LIKE escape character.
 */
function escapeLikePattern(value: string): string {
  return value.replace(/[\\%_]/g, (character) => `\\${character}`);
}

export const users = new Hono<AppEnv>();

users.use(requireAuth);

users.get("/me", async (context) => {
  try {
    const [user] = await database
      .select()
      .from(usersTable)
      .where(eq(usersTable.id, context.get("userId")));

    if (!user) {
      return context.json({ error: "User not found" }, 404);
    }

    return context.json(toPrivateUserResult(user));
  } catch (error) {
    console.error(error);
    return context.json({ error: "Failed to fetch profile" }, 500);
  }
});

users.patch("/me", async (context) => {
  let body: unknown;
  try {
    body = await context.req.json();
  } catch {
    return context.json({ error: "Invalid JSON body" }, 400);
  }

  const parsed = updateProfileSchema.safeParse(body);
  if (!parsed.success) {
    return context.json({ error: "Invalid profile update", details: parsed.error.flatten() }, 400);
  }

  const userId = context.get("userId");

  // Without this, any user could point their avatar at any object in the
  // bucket — including another user's photo — because the key is just a
  // string the client sends. Null is allowed: that is how a photo is removed.
  if (
    parsed.data.avatarKey !== undefined &&
    parsed.data.avatarKey !== null &&
    !isOwnedAvatarKey(parsed.data.avatarKey, userId)
  ) {
    return context.json({ error: "Invalid avatar key" }, 400);
  }

  try {
    const [updated] = await database
      .update(usersTable)
      .set(parsed.data)
      .where(eq(usersTable.id, userId))
      .returning();

    if (!updated) {
      return context.json({ error: "User not found" }, 404);
    }

    return context.json(toPrivateUserResult(updated));
  } catch (error) {
    console.error(error);
    return context.json({ error: "Failed to update profile" }, 500);
  }
});

users.post("/me/avatar-upload", async (context) => {
  let body: unknown;
  try {
    body = await context.req.json();
  } catch {
    return context.json({ error: "Invalid JSON body" }, 400);
  }

  const parsed = avatarUploadSchema.safeParse(body);
  if (!parsed.success) {
    return context.json({ error: "Invalid upload request", details: parsed.error.flatten() }, 400);
  }

  try {
    const upload = await createAvatarUploadUrl(context.get("userId"), parsed.data.contentLength);
    return context.json(upload);
  } catch (error) {
    console.error(error);
    return context.json({ error: "Failed to create upload url" }, 500);
  }
});

// Registered before /:id, which would otherwise reject "search" as an
// invalid user id.
users.get("/search", async (context) => {
  const parsed = searchQuerySchema.safeParse(context.req.query());
  if (!parsed.success) {
    return context.json(
      { error: "Invalid query parameters", details: parsed.error.flatten() },
      400,
    );
  }

  const currentUserId = context.get("userId");

  try {
    const rows = await database
      .select()
      .from(usersTable)
      .where(
        and(
          ilike(usersTable.name, `%${escapeLikePattern(parsed.data.q)}%`),
          ne(usersTable.id, currentUserId),
          // Someone who has not set a name yet can't be recognised in a list
          // of results, so they aren't findable until they do.
          isNotNull(usersTable.name),
        ),
      )
      .orderBy(asc(usersTable.name))
      .limit(SEARCH_RESULT_LIMIT);

    const friendshipStateFor = await loadFriendshipStates(
      currentUserId,
      rows.map((row) => row.id),
    );

    return context.json({
      results: rows.map((row) => {
        const friendshipState = friendshipStateFor(row.id);
        return {
          ...toPublicUserResult(row),
          friendshipStatus: friendshipState.status,
          friendRequestId: friendshipState.friendRequestId,
        };
      }),
    });
  } catch (error) {
    console.error(error);
    return context.json({ error: "Failed to search users" }, 500);
  }
});

users.get("/:id", async (context) => {
  const parsed = idParamSchema.safeParse({ id: context.req.param("id") });
  if (!parsed.success) {
    return context.json({ error: "Invalid user id" }, 400);
  }

  try {
    const [user] = await database
      .select()
      .from(usersTable)
      .where(eq(usersTable.id, parsed.data.id));

    if (!user) {
      return context.json({ error: "User not found" }, 404);
    }

    // The count is visible to anyone, friend or not; the checkins themselves
    // are only listed for friends (see isVisibleCheckin). Private checkins
    // only count toward your own total, so the number can't reveal them.
    const isOwnProfile = user.id === context.get("userId");
    const [checkinTotal] = await database
      .select({ value: count() })
      .from(checkinsTable)
      .where(
        and(
          eq(checkinsTable.userId, user.id),
          isOwnProfile ? undefined : eq(checkinsTable.visibility, "public"),
        ),
      );
    // Like the checkin count, public; who the friends are is not returned.
    const [friendTotal] = await database
      .select({ value: count() })
      .from(friendshipsTable)
      .where(
        and(
          eq(friendshipsTable.status, "accepted"),
          or(eq(friendshipsTable.requesterId, user.id), eq(friendshipsTable.addresseeId, user.id)),
        ),
      );
    const friendshipStateFor = await loadFriendshipStates(context.get("userId"), [user.id]);
    const friendshipState = friendshipStateFor(user.id);

    // Public shape: no email, and nothing about how they sign in.
    return context.json({
      ...toPublicUserResult(user),
      checkinCount: checkinTotal?.value ?? 0,
      friendCount: friendTotal?.value ?? 0,
      friendshipStatus: friendshipState.status,
      friendRequestId: friendshipState.friendRequestId,
    });
  } catch (error) {
    console.error(error);
    return context.json({ error: "Failed to fetch user" }, 500);
  }
});
