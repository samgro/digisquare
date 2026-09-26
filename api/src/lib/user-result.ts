import type { users } from "../db/schema.js";
import { publicUrlFor } from "./r2.js";

type UserRow = typeof users.$inferSelect;

export function avatarUrlFor(avatarKey: string | null): string | null {
  if (!avatarKey) {
    return null;
  }
  return publicUrlFor(avatarKey);
}

/**
 * The caller's own profile. Carries the email and which sign-in methods are
 * attached, so the Profile screen can render them without a second request.
 *
 * avatarKey is deliberately absent: clients only ever see the public URL.
 */
export function toPrivateUserResult(user: UserRow) {
  return {
    id: user.id,
    email: user.email,
    name: user.name,
    bio: user.bio,
    avatarUrl: avatarUrlFor(user.avatarKey),
    hometown: user.hometown,
    hasAppleSignIn: user.appleUserId !== null,
    createdAt: user.createdAt,
  };
}

/**
 * Just enough to draw someone's avatar and name next to a feed row, without
 * repeating their bio on every checkin.
 */
export function toUserSummary(user: UserRow) {
  return {
    id: user.id,
    name: user.name,
    avatarUrl: avatarUrlFor(user.avatarKey),
  };
}

/** Somebody else's profile. Never includes the email. */
export function toPublicUserResult(user: UserRow) {
  return {
    id: user.id,
    name: user.name,
    bio: user.bio,
    avatarUrl: avatarUrlFor(user.avatarKey),
    hometown: user.hometown,
    createdAt: user.createdAt,
  };
}
