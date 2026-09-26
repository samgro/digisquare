import {
  pgTable,
  uuid,
  text,
  integer,
  doublePrecision,
  boolean,
  timestamp,
  geometry,
  customType,
  index,
  uniqueIndex,
  primaryKey,
  check,
} from "drizzle-orm/pg-core";
import { sql } from "drizzle-orm";
import { jsonb } from "drizzle-orm/pg-core";

/**
 * A PostGIS multipolygon. Drizzle only knows points natively, so this is
 * declared as a custom type; it is only ever read and written through raw
 * SQL (`ST_AsGeoJSON`, `ST_GeomFromGeoJSON`), never as a JavaScript value.
 */
const multiPolygon = customType<{ data: string; driverData: string }>({
  dataType() {
    return "geometry(MultiPolygon, 4326)";
  },
});

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
    // without one, and the profile setup screen collects it.
    name: text("name"),
    bio: text("bio"),
    // R2 object key. Never returned to clients — user-result.ts maps it to a
    // public avatarUrl instead.
    avatarKey: text("avatar_key"),
    // Display text such as "San Francisco, CA", formatted on the device by
    // MapKit. Required, but nullable for the same reason as name: the row is
    // created at signup, before the profile setup screen collects it. The
    // PATCH schema refuses to clear it, and the app will not leave setup
    // until it is set.
    hometown: text("hometown"),

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

// "friends" is everyone the owner is friends with; there are no public
// checkins yet.
export const CHECKIN_VISIBILITIES = ["friends", "private"] as const;
export type CheckinVisibility = (typeof CHECKIN_VISIBILITIES)[number];

// "swarm" rows were imported from the user's Swarm history; they carry Swarm's
// checkin id in externalId.
export const CHECKIN_SOURCES = ["manual", "visit", "swarm"] as const;
export type CheckinSource = (typeof CHECKIN_SOURCES)[number];

// Foursquare's category tree, upserted from /v2/venues/categories at the start
// of every Swarm import. Ids are Foursquare's 24-hex category ids, which the
// newer Places API also uses, so they stay useful for matching later.
export const foursquareCategories = pgTable("foursquare_categories", {
  id: text("id").primaryKey(),
  name: text("name").notNull(),
  pluralName: text("plural_name"),
  shortName: text("short_name"),
  // Foursquare's numeric id for the same category (e.g. 13035), kept because
  // some Foursquare products still key on it.
  categoryCode: integer("category_code"),
  parentId: text("parent_id"),
  iconPrefix: text("icon_prefix"),
  iconSuffix: text("icon_suffix"),
  // The Overture category this one reconciles to, resolved from
  // lib/foursquare-category-mapping.ts. Stored so it can be queried and
  // corrected per row without a deploy; null when Overture has nothing close.
  overtureCategory: text("overture_category"),
  updatedAt: timestamp("updated_at", { withTimezone: true })
    .notNull()
    .defaultNow()
    .$onUpdate(() => new Date()),
});

/**
 * A Foursquare venue seen in an imported Swarm checkin, exactly as Foursquare
 * described it, raw payload included. The `places` row the checkins point at
 * is made from this; keeping the original alongside means venues can be
 * matched to Overture places later without going back to Foursquare.
 */
export const foursquareVenues = pgTable("foursquare_venues", {
  id: text("id").primaryKey(),
  name: text("name").notNull(),
  address: text("address"),
  crossStreet: text("cross_street"),
  city: text("city"),
  state: text("state"),
  postalCode: text("postal_code"),
  countryCode: text("country_code"),
  country: text("country"),
  formattedAddress: text("formatted_address"),
  latitude: doublePrecision("latitude"),
  longitude: doublePrecision("longitude"),
  // No foreign key: a venue can arrive naming a category that is missing
  // from the category tree Foursquare returned.
  primaryCategoryId: text("primary_category_id"),
  categoryIds: text("category_ids").array(),
  raw: jsonb("raw").notNull(),
  updatedAt: timestamp("updated_at", { withTimezone: true })
    .notNull()
    .defaultNow()
    .$onUpdate(() => new Date()),
});

/**
 * Every venue a checkin can point at. Rows come from four places: the
 * Overture Maps places dataset (imported with `npm run overture:import`, keyed
 * by GERS id), venues users create from the app, the venues the old
 * Google-backed checkins referenced, backfilled by migration 0008 so history
 * kept its identity when the Google Places integration was removed, and the
 * venues of imported Swarm checkins (one row per Foursquare venue, made from
 * `foursquare_venues`). Foursquare rows are kept out of search until they are
 * matched to Overture's copy of the same venue, so nothing shows up twice.
 *
 * `types` are Overture category codes (`coffee_shop`, `airport`, ...), the
 * primary one first. The old Google types on `google` rows and Foursquare's
 * categories on `foursquare` rows were mapped to the closest Overture
 * category where one exists; `categoryName` keeps the source's own label.
 *
 * `location` is a PostGIS point kept in step with `latitude`/`longitude` by
 * Postgres itself (a generated column), so the GiST index serves the nearby
 * searches while the API keeps reading plain coordinates. `extent` is the
 * venue's grounds as a polygon, when Overture's base theme has one (an
 * airport, a park, a campus), matched by `extent-matching.ts`.
 */
export const places = pgTable(
  "places",
  {
    id: uuid("id").primaryKey().defaultRandom(),

    source: text("source", { enum: ["overture", "user", "google", "foursquare"] }).notNull(),
    // Overture's GERS id. Stable across releases, so re-importing upserts.
    overtureId: text("overture_id"),
    // Only on rows backfilled from pre-Overture checkins.
    googlePlaceId: text("google_place_id"),
    // Only on rows made by a Swarm import, which upserts on it.
    foursquareVenueId: text("foursquare_venue_id").references(() => foursquareVenues.id),

    name: text("name").notNull(),
    primaryType: text("primary_type"),
    types: text("types").array().notNull().default(sql`'{}'::text[]`),
    // The source's own label for the primary category, when it has one.
    // Overture rows have none: the app labels their codes itself. A
    // Foursquare venue keeps Foursquare's name, so "Hotpot Restaurant"
    // survives mapping to the broader asian_restaurant, and a category the
    // Overture taxonomy lacks altogether still has a label to show.
    categoryName: text("category_name"),

    // Overture's address parts: `freeform` is the street line (house number
    // and street), `region` an ISO 3166-2 code such as US-CA and `country`
    // an ISO 3166-1 alpha-2 code. User-created venues follow the same shape.
    addressStreet: text("address_street"),
    addressLocality: text("address_locality"),
    addressRegion: text("address_region"),
    addressPostcode: text("address_postcode"),
    addressCountry: text("address_country"),

    // Nullable only for legacy rows: the app never saved a coordinate for
    // some Google places. Overture and user venues always have a pin.
    latitude: doublePrecision("latitude"),
    longitude: doublePrecision("longitude"),
    location: geometry("location", { type: "point", mode: "xy", srid: 4326 }).generatedAlwaysAs(
      sql`ST_SetSRID(ST_MakePoint(longitude, latitude), 4326)`,
    ),

    extent: multiPolygon("extent"),
    // The base-theme feature the extent came from, so re-imports replace
    // rather than duplicate, and its area for choosing between overlaps.
    extentOvertureId: text("extent_overture_id"),
    extentAreaSquareMeters: doublePrecision("extent_area_square_meters"),

    // A private venue is found in searches only by its creator and their
    // friends. Overture and legacy rows are public.
    isPrivate: boolean("is_private").notNull().default(false),

    // The Overture release this row was last present in. A refresh retires
    // rows the new release no longer has (see coverage-worker.ts) instead of
    // deleting them, because checkins point at them.
    lastSeenRelease: text("last_seen_release"),
    retiredAt: timestamp("retired_at", { withTimezone: true }),

    // Overture's 0..1 existence confidence. Null for other sources.
    confidence: doublePrecision("confidence"),
    website: text("website"),
    phone: text("phone"),

    // Who added a `user` venue. Kept when the account is deleted so other
    // people's checkins there keep a valid place.
    createdByUserId: uuid("created_by_user_id").references(() => users.id, {
      onDelete: "set null",
    }),

    createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
    updatedAt: timestamp("updated_at", { withTimezone: true })
      .notNull()
      .defaultNow()
      .$onUpdate(() => new Date()),
  },
  (table) => [
    uniqueIndex("places_overture_id_unique_idx").on(table.overtureId),
    uniqueIndex("places_google_place_id_unique_idx").on(table.googlePlaceId),
    uniqueIndex("places_foursquare_venue_id_unique_idx").on(table.foursquareVenueId),
    // Indexed as geography, which is what the searches compare in meters;
    // a plain geometry index would sit unused behind the cast.
    index("places_location_gist_idx").using("gist", sql`(${table.location}::geography)`),
    index("places_extent_gist_idx").using("gist", sql`(${table.extent}::geography)`),
    // And as plain geometry, for the predicates that never cast: matching
    // venue grounds to the pins inside them (ST_Contains) and finding the
    // places inside an imported area's box (&&). Without it each of those
    // is a scan of the whole table.
    index("places_location_geometry_gist_idx").using("gist", table.location),
    // Trigram index so `name ILIKE '%cos%'` finds Costco without a scan.
    // Needs pg_trgm, which migration 0008 enables.
    index("places_name_trgm_idx").using("gin", sql`lower(${table.name}) gin_trgm_ops`),
    index("places_created_by_user_id_idx").on(table.createdByUserId),
    check(
      "places_source_check",
      sql`${table.source} in ('overture', 'user', 'google', 'foursquare')`,
    ),
    check(
      "places_source_identifier_check",
      sql`(${table.source} = 'overture') = (${table.overtureId} is not null) and (${table.source} = 'google') = (${table.googlePlaceId} is not null) and (${table.source} = 'foursquare') = (${table.foursquareVenueId} is not null)`,
    ),
  ],
);

/**
 * One background fetch of Overture data for a bounding box. `fix` jobs are
 * the few cells around a user who searched somewhere uncovered; `city` jobs
 * grow that to the whole city afterwards; `seed` jobs load a region an
 * operator asked for; `refresh` jobs roll ready cells to a newer release.
 * Lower `priority` runs first, so a waiting user always beats a city.
 */
export const coverageJobs = pgTable(
  "coverage_jobs",
  {
    id: uuid("id").primaryKey().defaultRandom(),
    kind: text("kind", { enum: ["fix", "city", "seed", "refresh"] }).notNull(),
    priority: integer("priority").notNull(),
    west: doublePrecision("west").notNull(),
    south: doublePrecision("south").notNull(),
    east: doublePrecision("east").notNull(),
    north: doublePrecision("north").notNull(),
    status: text("status", { enum: ["pending", "importing", "ready", "failed"] })
      .notNull()
      .default("pending"),
    requestedByUserId: uuid("requested_by_user_id").references(() => users.id, {
      onDelete: "set null",
    }),
    // The fix job a city job grew out of. No foreign key: it points within
    // the same table and adds nothing.
    parentJobId: uuid("parent_job_id"),
    overtureRelease: text("overture_release").notNull(),
    attempts: integer("attempts").notNull().default(0),
    lastError: text("last_error"),
    placeCount: integer("place_count"),
    extentCount: integer("extent_count"),
    requestedAt: timestamp("requested_at", { withTimezone: true }).notNull().defaultNow(),
    startedAt: timestamp("started_at", { withTimezone: true }),
    // Bumped every minute while a worker is on the job. A job whose
    // heartbeat stops is one whose worker died, and it goes back to the
    // queue; a long job that keeps beating is left alone.
    heartbeatAt: timestamp("heartbeat_at", { withTimezone: true }),
    completedAt: timestamp("completed_at", { withTimezone: true }),
  },
  (table) => [
    index("coverage_jobs_status_priority_idx").on(table.status, table.priority, table.requestedAt),
    check(
      "coverage_jobs_bounds_check",
      sql`${table.west} <= ${table.east} and ${table.south} <= ${table.north}`,
    ),
  ],
);

/**
 * Which 0.1 degree cells of the world hold Overture data. A search from a
 * cell that is not `ready` is what triggers a fetch. Cells are keyed by
 * floor(longitude / 0.1), floor(latitude / 0.1).
 */
export const coverageCells = pgTable(
  "coverage_cells",
  {
    cellX: integer("cell_x").notNull(),
    cellY: integer("cell_y").notNull(),
    status: text("status", { enum: ["pending", "ready", "failed"] }).notNull(),
    jobId: uuid("job_id").references(() => coverageJobs.id, { onDelete: "set null" }),
    overtureRelease: text("overture_release"),
    readyAt: timestamp("ready_at", { withTimezone: true }),
    updatedAt: timestamp("updated_at", { withTimezone: true })
      .notNull()
      .defaultNow()
      .$onUpdate(() => new Date()),
  },
  (table) => [
    primaryKey({ columns: [table.cellX, table.cellY] }),
    index("coverage_cells_status_idx").on(table.status),
    index("coverage_cells_job_id_idx").on(table.jobId),
  ],
);

export const checkins = pgTable(
  "checkins",
  {
    id: uuid("id").primaryKey().defaultRandom(),

    userId: uuid("user_id")
      .notNull()
      .references(() => users.id, { onDelete: "cascade" }),

    placeId: uuid("place_id")
      .notNull()
      .references(() => places.id),
    // A snapshot of the place at checkin time, so a timeline never changes
    // under the user when the venue is renamed or re-imported.
    placeName: text("place_name").notNull(),
    placeAddress: text("place_address"),
    placeLocality: text("place_locality"),
    // The place's `addressRegion` (ISO 3166-2, e.g. US-CA) and
    // `addressCountry` (ISO 3166-1 alpha-2), so the app can filter a
    // history by state and country without parsing the address line.
    placeRegion: text("place_region"),
    placeCountry: text("place_country"),
    placePrimaryType: text("place_primary_type"),
    placeTypes: text("place_types").array(),
    // The place's categoryName at checkin time: a label such as "Hotpot
    // Restaurant" when the source gave one.
    placeCategoryName: text("place_category_name"),
    latitude: doublePrecision("latitude"),
    longitude: doublePrecision("longitude"),

    message: text("message"),

    /** Who can see the checkin. Private checkins never appear in the friends feed. */
    visibility: text("visibility", { enum: CHECKIN_VISIBILITIES }).notNull().default("friends"),
    /**
     * Whether the user checked in by hand, accepted a suggestion from a
     * detected visit, or imported the checkin from Swarm.
     */
    source: text("source", { enum: CHECKIN_SOURCES }).notNull().default("manual"),
    // The source's id for an imported checkin, which is what makes
    // re-importing an upsert.
    externalId: text("external_id"),

    // The checkin's local offset from UTC, so history shows the time where it
    // happened rather than where the reader is.
    timeZoneOffsetMinutes: integer("time_zone_offset_minutes"),

    createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
    updatedAt: timestamp("updated_at", { withTimezone: true })
      .notNull()
      .defaultNow()
      .$onUpdate(() => new Date()),
  },
  (table) => [
    index("checkins_user_id_idx").on(table.userId),
    index("checkins_place_id_idx").on(table.placeId),
    // Per user, so two accounts that connect the same Swarm account each get
    // their own copy rather than one import rewriting the other's rows.
    uniqueIndex("checkins_user_source_external_id_unique_idx")
      .on(table.userId, table.source, table.externalId)
      .where(sql`${table.externalId} is not null`),
    // Keyset indexes for the two phases of GET /checkins/sync.
    index("checkins_user_id_created_at_id_idx").on(table.userId, table.createdAt, table.id),
    index("checkins_user_id_updated_at_id_idx").on(table.userId, table.updatedAt, table.id),
  ],
);

// The source's full payload for an imported checkin: companions, event,
// likes, sticker and everything else we don't model yet.
export const importedCheckinPayloads = pgTable("imported_checkin_payloads", {
  checkinId: uuid("checkin_id")
    .primaryKey()
    .references(() => checkins.id, { onDelete: "cascade" }),
  source: text("source", { enum: ["swarm"] }).notNull(),
  payload: jsonb("payload").notNull(),
  fetchedAt: timestamp("fetched_at", { withTimezone: true }).notNull().defaultNow(),
});

// A photo on a checkin. Uploaded photos have a storageKey from the start.
// Imported photos start with only sourceUrl, which is served until the
// background copy to R2 fills in storageKey.
export const checkinPhotos = pgTable(
  "checkin_photos",
  {
    id: uuid("id").primaryKey().defaultRandom(),
    checkinId: uuid("checkin_id")
      .notNull()
      .references(() => checkins.id, { onDelete: "cascade" }),
    position: integer("position").notNull().default(0),
    storageKey: text("storage_key"),
    sourceUrl: text("source_url"),
    // The source's photo id, for imported photos.
    externalId: text("external_id"),
    width: integer("width"),
    height: integer("height"),
    // Set when the copy to R2 gave up; the photo keeps serving sourceUrl.
    copyFailedAt: timestamp("copy_failed_at", { withTimezone: true }),
    createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
  },
  (table) => [
    index("checkin_photos_checkin_id_idx").on(table.checkinId),
    uniqueIndex("checkin_photos_checkin_external_id_unique_idx").on(
      table.checkinId,
      table.externalId,
    ),
    check(
      "checkin_photos_has_location_check",
      sql`${table.storageKey} is not null or ${table.sourceUrl} is not null`,
    ),
  ],
);

// A user's linked Foursquare account. The token is long-lived with no
// refresh, so it is stored encrypted (lib/token-encryption.ts).
export const foursquareConnections = pgTable("foursquare_connections", {
  userId: uuid("user_id")
    .primaryKey()
    .references(() => users.id, { onDelete: "cascade" }),
  foursquareUserId: text("foursquare_user_id").notNull(),
  accessTokenCiphertext: text("access_token_ciphertext").notNull(),
  connectedAt: timestamp("connected_at", { withTimezone: true }).notNull().defaultNow(),
  lastImportedAt: timestamp("last_imported_at", { withTimezone: true }),
});

// One run of the Swarm importer. Progress is saved after every page so a run
// interrupted by a deploy resumes where it stopped.
export const swarmImports = pgTable(
  "swarm_imports",
  {
    id: uuid("id").primaryKey().defaultRandom(),
    userId: uuid("user_id")
      .notNull()
      .references(() => users.id, { onDelete: "cascade" }),
    status: text("status", { enum: ["running", "completed", "failed"] })
      .notNull()
      .default("running"),
    phase: text("phase", { enum: ["checkins", "photos"] })
      .notNull()
      .default("checkins"),
    // Unix seconds. beforeTimestamp is the resume cursor; afterTimestamp
    // bounds an incremental sync.
    beforeTimestamp: integer("before_timestamp"),
    afterTimestamp: integer("after_timestamp"),
    checkinsImported: integer("checkins_imported").notNull().default(0),
    // How many checkins this run should bring in, from Foursquare's count of
    // the user's checkins less what earlier runs already imported. Null until
    // Foursquare has been asked, when the app shows progress as indeterminate.
    checkinsExpected: integer("checkins_expected"),
    photosTotal: integer("photos_total").notNull().default(0),
    photosCopied: integer("photos_copied").notNull().default(0),
    error: text("error"),
    startedAt: timestamp("started_at", { withTimezone: true }).notNull().defaultNow(),
    finishedAt: timestamp("finished_at", { withTimezone: true }),
  },
  (table) => [
    index("swarm_imports_user_id_started_at_idx").on(table.userId, table.startedAt.desc()),
    // At most one running import per user, so two taps on Sync cannot race.
    uniqueIndex("swarm_imports_one_running_per_user_idx")
      .on(table.userId)
      .where(sql`${table.status} = 'running'`),
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

// One row per person per checkin; the unique index is what makes a double
// tap on the heart a no-op rather than a race (neon-http has no interactive
// transactions to check-then-insert inside).
export const checkinLikes = pgTable(
  "checkin_likes",
  {
    id: uuid("id").primaryKey().defaultRandom(),

    checkinId: uuid("checkin_id")
      .notNull()
      .references(() => checkins.id, { onDelete: "cascade" }),
    userId: uuid("user_id")
      .notNull()
      .references(() => users.id, { onDelete: "cascade" }),

    createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
  },
  (table) => [
    uniqueIndex("checkin_likes_checkin_user_unique_idx").on(table.checkinId, table.userId),
  ],
);

export const checkinComments = pgTable(
  "checkin_comments",
  {
    id: uuid("id").primaryKey().defaultRandom(),

    checkinId: uuid("checkin_id")
      .notNull()
      .references(() => checkins.id, { onDelete: "cascade" }),
    userId: uuid("user_id")
      .notNull()
      .references(() => users.id, { onDelete: "cascade" }),

    body: text("body").notNull(),

    createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
    updatedAt: timestamp("updated_at", { withTimezone: true })
      .notNull()
      .defaultNow()
      .$onUpdate(() => new Date()),
  },
  (table) => [
    index("checkin_comments_checkin_created_idx").on(table.checkinId, table.createdAt),
  ],
);

export const NOTIFICATION_KINDS = ["like", "comment", "friend_request", "friend_accepted"] as const;
export type NotificationKind = (typeof NOTIFICATION_KINDS)[number];

// What the bell shows: someone liked or commented on one of your checkins,
// asked to be your friend, or accepted your request. Every row points at its
// subject (a checkin or a friendship) with a cascading foreign key, so the
// notification disappears with the thing it was about: a deleted comment, a
// cancelled request, an unfriending.
export const notifications = pgTable(
  "notifications",
  {
    id: uuid("id").primaryKey().defaultRandom(),

    recipientId: uuid("recipient_id")
      .notNull()
      .references(() => users.id, { onDelete: "cascade" }),
    actorId: uuid("actor_id")
      .notNull()
      .references(() => users.id, { onDelete: "cascade" }),

    kind: text("kind", { enum: NOTIFICATION_KINDS }).notNull(),

    checkinId: uuid("checkin_id").references(() => checkins.id, { onDelete: "cascade" }),
    commentId: uuid("comment_id").references(() => checkinComments.id, { onDelete: "cascade" }),
    friendshipId: uuid("friendship_id").references(() => friendships.id, { onDelete: "cascade" }),

    readAt: timestamp("read_at", { withTimezone: true }),
    createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
  },
  (table) => [
    index("notifications_recipient_created_idx").on(table.recipientId, table.createdAt),
    index("notifications_recipient_read_idx").on(table.recipientId, table.readAt),
    // Unliking keeps the notification and re-liking hits this index, so a
    // heart tapped on and off never badges the owner twice.
    uniqueIndex("notifications_like_once_idx")
      .on(table.recipientId, table.actorId, table.checkinId)
      .where(sql`${table.kind} = 'like'`),
    uniqueIndex("notifications_friend_request_once_idx")
      .on(table.friendshipId)
      .where(sql`${table.kind} = 'friend_request'`),
    check("notifications_not_self_check", sql`${table.recipientId} <> ${table.actorId}`),
    check(
      "notifications_subject_check",
      sql`(${table.kind} in ('like', 'comment') and ${table.checkinId} is not null) or (${table.kind} in ('friend_request', 'friend_accepted') and ${table.friendshipId} is not null)`,
    ),
  ],
);
