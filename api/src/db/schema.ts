import {
  pgTable,
  uuid,
  text,
  integer,
  doublePrecision,
  timestamp,
  boolean,
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

    // Seeded or created through /auth/test-users, which only exists when
    // ENABLE_TEST_USERS is set. Test users have no credential of their own.
    isTestUser: boolean("is_test_user").notNull().default(false),

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
      sql`${table.appleUserId} is not null or ${table.isTestUser}`,
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

// One row per pair of users. A pending row is a friend request from
// requesterId to addresseeId; an accepted row is a friendship, which is
// symmetric no matter who asked. Declining keeps the row as "declined", which
// the requester still sees as pending so they never learn they were declined;
// the addressee can take it back by adding the requester. Cancelling and
// unfriending delete the row.
export const friendships = pgTable(
  "friendships",
  {
    id: uuid("id").primaryKey().defaultRandom(),

    requesterId: uuid("requester_id")
      .notNull()
      .references(() => users.id, { onDelete: "cascade" }),
    addresseeId: uuid("addressee_id")
      .notNull()
      .references(() => users.id, { onDelete: "cascade" }),

    status: text("status", { enum: ["pending", "accepted", "declined"] })
      .notNull()
      .default("pending"),

    createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
    updatedAt: timestamp("updated_at", { withTimezone: true })
      .notNull()
      .defaultNow()
      .$onUpdate(() => new Date()),
  },
  (table) => [
    // Unique on the unordered pair, so A→B and B→A cannot both exist. This is
    // what settles two people tapping Add on each other at the same moment:
    // neon-http has no interactive transactions, so a select-then-insert
    // check would race.
    uniqueIndex("friendships_pair_unique_idx").on(
      sql`least(${table.requesterId}, ${table.addresseeId})`,
      sql`greatest(${table.requesterId}, ${table.addresseeId})`,
    ),
    index("friendships_requester_status_idx").on(table.requesterId, table.status),
    index("friendships_addressee_status_idx").on(table.addresseeId, table.status),
    check("friendships_not_self_check", sql`${table.requesterId} <> ${table.addresseeId}`),
  ],
);
