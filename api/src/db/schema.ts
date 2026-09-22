import {
  pgTable,
  uuid,
  text,
  integer,
  doublePrecision,
  timestamp,
  index,
  uniqueIndex,
  check,
} from "drizzle-orm/pg-core";
import { sql } from "drizzle-orm";

export const users = pgTable(
  "users",
  {
    id: uuid("id").primaryKey().defaultRandom(),

    // Nullable, and unique only when present. Postgres treats NULLs as
    // distinct in a unique index, so any number of rows may have a null
    // email — that is load-bearing for the no-auto-link rule in
    // routes/auth.ts, which parks an Apple account's email in appleEmail and
    // leaves the unique email slot with the pre-existing account. Do not
    // "fix" this by making the column NOT NULL.
    email: text("email"),
    emailVerifiedAt: timestamp("email_verified_at", { withTimezone: true }),
    passwordHash: text("password_hash"),

    // Apple's stable `sub` claim. The only identifier we ever match an Apple
    // sign-in on — never the email, which the user can hide or change.
    appleUserId: text("apple_user_id"),
    // Informational: what Apple told us, kept so a future account-linking
    // pass can reconcile a collision. Deliberately not unique.
    appleEmail: text("apple_email"),

    // Nullable because Apple returns fullName only on the very first
    // authorization; a user who reinstalls before we persist it arrives
    // without one, and NameSetupView collects it.
    name: text("name"),
    bio: text("bio"),
    // R2 object key. Never returned to clients — user-result.ts maps it to a
    // public avatarUrl instead.
    avatarKey: text("avatar_key"),

    createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
    updatedAt: timestamp("updated_at", { withTimezone: true })
      .notNull()
      .defaultNow()
      .$onUpdate(() => new Date()),
  },
  (table) => [
    uniqueIndex("users_email_unique_idx").on(table.email),
    uniqueIndex("users_apple_user_id_unique_idx").on(table.appleUserId),
    check(
      "users_has_credential_check",
      sql`${table.passwordHash} is not null or ${table.appleUserId} is not null`,
    ),
  ],
);

export const sessions = pgTable(
  "sessions",
  {
    id: uuid("id").primaryKey().defaultRandom(),
    userId: uuid("user_id")
      .notNull()
      .references(() => users.id, { onDelete: "cascade" }),

    // Constant across every rotation of one sign-in. Replaying a rotated
    // token revokes the whole family, which is what makes theft of a refresh
    // token self-limiting.
    familyId: uuid("family_id").notNull(),
    familyStartedAt: timestamp("family_started_at", { withTimezone: true })
      .notNull()
      .defaultNow(),
    // sha256 hex of the opaque token. The token itself is never stored.
    refreshTokenHash: text("refresh_token_hash").notNull(),
    // The successor issued when this row was rotated. Powers the grace window
    // for a rotation whose response was lost in transit. Intentionally no
    // foreign key: it points within the same table and adds nothing.
    replacedBySessionId: uuid("replaced_by_session_id"),

    expiresAt: timestamp("expires_at", { withTimezone: true }).notNull(),
    rotatedAt: timestamp("rotated_at", { withTimezone: true }),
    revokedAt: timestamp("revoked_at", { withTimezone: true }),
    // logout | reuse_detected | family_expired
    revokedReason: text("revoked_reason"),

    userAgent: text("user_agent"),
    ipAddress: text("ip_address"),

    createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
  },
  (table) => [
    uniqueIndex("sessions_refresh_token_hash_unique_idx").on(table.refreshTokenHash),
    index("sessions_user_id_idx").on(table.userId),
    index("sessions_family_id_idx").on(table.familyId),
    index("sessions_expires_at_idx").on(table.expiresAt),
  ],
);

// Fixed-window counters for the auth endpoints. Backed by Postgres rather
// than process memory because Railway may run more than one instance, where
// an in-memory limiter silently becomes `instances x limit` and resets on
// every deploy.
export const authRateLimits = pgTable("auth_rate_limits", {
  bucketKey: text("bucket_key").primaryKey(),
  windowStartedAt: timestamp("window_started_at", { withTimezone: true }).notNull(),
  attemptCount: integer("attempt_count").notNull().default(0),
});

export const checkins = pgTable(
  "checkins",
  {
    id: uuid("id").primaryKey().defaultRandom(),

    userId: uuid("user_id")
      .notNull()
      .references(() => users.id, { onDelete: "cascade" }),

    googlePlaceId: text("google_place_id").notNull(),
    placeName: text("place_name").notNull(),
    placeAddress: text("place_address"),
    placePrimaryType: text("place_primary_type"),
    placeTypes: text("place_types").array(),
    latitude: doublePrecision("latitude"),
    longitude: doublePrecision("longitude"),

    message: text("message"),

    createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
    updatedAt: timestamp("updated_at", { withTimezone: true })
      .notNull()
      .defaultNow()
      .$onUpdate(() => new Date()),
  },
  (table) => [
    index("checkins_user_id_idx").on(table.userId),
    index("checkins_google_place_id_idx").on(table.googlePlaceId),
  ],
);
