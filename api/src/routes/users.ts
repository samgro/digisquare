import { Hono } from "hono";
import { eq } from "drizzle-orm";
import { z } from "zod";
import { database } from "../db/index.js";
import { users as usersTable } from "../db/schema.js";
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

    // Public shape: no email, and nothing about how they sign in.
    return context.json(toPublicUserResult(user));
  } catch (error) {
    console.error(error);
    return context.json({ error: "Failed to fetch user" }, 500);
  }
});
