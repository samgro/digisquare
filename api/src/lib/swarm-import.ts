import { randomUUID } from "node:crypto";
import { and, asc, count, desc, eq, inArray, isNotNull, isNull, max, sql } from "drizzle-orm";
import type { BatchItem } from "drizzle-orm/batch";
import sharp, { type OutputInfo } from "sharp";
import { swarmImportConfig } from "../config.js";
import { database } from "../db/index.js";
import {
  checkinPhotos as checkinPhotosTable,
  checkins as checkinsTable,
  foursquareCategories as foursquareCategoriesTable,
  foursquareConnections as foursquareConnectionsTable,
  foursquareVenues as foursquareVenuesTable,
  importedCheckinPayloads as importedCheckinPayloadsTable,
  places as placesTable,
  swarmImports as swarmImportsTable,
} from "../db/schema.js";
import { isUniqueViolation } from "./database-errors.js";
import {
  fetchCategories,
  fetchCheckinsPage,
  fetchSelf,
  FoursquareError,
  photoUrl,
  type FoursquareCategory,
  type FoursquareCheckin,
  type FoursquareVenue,
} from "./foursquare.js";
import {
  overtureCategoryForFoursquareCategory,
  type CategoryNode,
} from "./foursquare-category-mapping.js";
import { formatAddress } from "./place-result.js";
import { putJpegObject } from "./r2.js";
import { decryptToken } from "./token-encryption.js";

type SwarmImportRow = typeof swarmImportsTable.$inferSelect;
type CheckinInsert = typeof checkinsTable.$inferInsert;
type VenueInsert = typeof foursquareVenuesTable.$inferInsert;
type PlaceInsert = typeof placesTable.$inferInsert;
type PhotoInsert = typeof checkinPhotosTable.$inferInsert;

// How far back an incremental sync re-reads, so photos added after the last
// import are picked up.
const RESYNC_OVERLAP_SECONDS = 30 * 24 * 60 * 60;

// Copied photos are resized to fit this box and re-encoded, which keeps
// thousands of imported originals from dominating storage.
const PHOTO_MAX_DIMENSION = 1200;
const PHOTO_JPEG_QUALITY = 80;
const PHOTO_BATCH_SIZE = 20;
const PHOTO_COPY_CONCURRENCY = 4;

/** Imports running in this process, so a resume never starts a second copy. */
const runningImportIds = new Set<string>();

/**
 * Starts importing the user's Swarm history in the background and returns the
 * new import, or null if one is already running for them.
 *
 * An incremental sync re-reads from a month before the last import that got
 * through every checkin started. Until one has, each import reads everything:
 * an import that failed partway only read the newest pages, so the newest
 * checkin imported says nothing about whether older history is in.
 */
export async function startSwarmImport(userId: string): Promise<SwarmImportRow | null> {
  const [lastFullRead] = await database
    .select({ startedAt: max(swarmImportsTable.startedAt) })
    .from(swarmImportsTable)
    .where(and(eq(swarmImportsTable.userId, userId), eq(swarmImportsTable.phase, "photos")));
  const afterTimestamp = lastFullRead?.startedAt
    ? Math.floor(lastFullRead.startedAt.getTime() / 1000) - RESYNC_OVERLAP_SECONDS
    : null;

  let created: SwarmImportRow | undefined;
  try {
    [created] = await database
      .insert(swarmImportsTable)
      .values({ userId, afterTimestamp })
      .returning();
  } catch (error) {
    // swarm_imports_one_running_per_user_idx: an import is already running.
    if (isUniqueViolation(error)) {
      return null;
    }
    throw error;
  }

  void runSwarmImport(created!.id);
  return created!;
}

/**
 * Picks up imports a deploy or crash interrupted. Called once at boot; each
 * import carries its own cursor, and every write is an upsert, so redoing the
 * page that was in flight is harmless.
 */
export async function resumeRunningImports(): Promise<void> {
  const running = await database
    .select({ id: swarmImportsTable.id })
    .from(swarmImportsTable)
    .where(eq(swarmImportsTable.status, "running"));
  for (const swarmImport of running) {
    void runSwarmImport(swarmImport.id);
  }
}

async function runSwarmImport(importId: string): Promise<void> {
  if (runningImportIds.has(importId)) {
    return;
  }
  runningImportIds.add(importId);

  try {
    const [swarmImport] = await database
      .select()
      .from(swarmImportsTable)
      .where(eq(swarmImportsTable.id, importId));
    if (!swarmImport || swarmImport.status !== "running") {
      return;
    }

    const accessToken = await loadAccessToken(swarmImport.userId);
    if (swarmImport.phase === "checkins") {
      await importCheckins(swarmImport, accessToken);
      await database
        .update(swarmImportsTable)
        .set({ phase: "photos" })
        .where(eq(swarmImportsTable.id, importId));
    }
    await copyPhotos(swarmImport);

    const finishedAt = new Date();
    await database.batch([
      database
        .update(swarmImportsTable)
        .set({ status: "completed", finishedAt })
        .where(eq(swarmImportsTable.id, importId)),
      database
        .update(foursquareConnectionsTable)
        .set({ lastImportedAt: finishedAt })
        .where(eq(foursquareConnectionsTable.userId, swarmImport.userId)),
    ]);
  } catch (error) {
    console.error(`Swarm import ${importId} failed`, error);
    await database
      .update(swarmImportsTable)
      .set({ status: "failed", error: describeImportError(error), finishedAt: new Date() })
      .where(eq(swarmImportsTable.id, importId))
      .catch((updateError: unknown) => console.error(updateError));
  } finally {
    runningImportIds.delete(importId);
  }
}

/** What the app shows when an import fails. Never a raw stack or token. */
function describeImportError(error: unknown): string {
  if (error instanceof FoursquareError && (error.status === 401 || error.status === 403)) {
    return "Foursquare no longer accepts this connection. Reconnect Swarm and try again.";
  }
  if (error instanceof FoursquareError) {
    return "Foursquare had a problem. Try syncing again later.";
  }
  return "The import stopped unexpectedly. Try syncing again.";
}

async function loadAccessToken(userId: string): Promise<string> {
  const configuration = swarmImportConfig();
  if (!configuration) {
    throw new Error("Swarm import is not configured");
  }
  const [connection] = await database
    .select()
    .from(foursquareConnectionsTable)
    .where(eq(foursquareConnectionsTable.userId, userId));
  if (!connection) {
    throw new Error("Swarm is not connected");
  }
  return decryptToken(connection.accessTokenCiphertext, configuration.tokenEncryptionKey);
}

async function importCheckins(swarmImport: SwarmImportRow, accessToken: string): Promise<void> {
  const categories = await fetchCategories(accessToken);
  const categoriesById = new Map<string, CategoryNode>(
    categories.map((category) => [category.id, category]),
  );
  await upsertCategories(categories, categoriesById);

  if (swarmImport.checkinsExpected === null) {
    await recordExpectedCount(swarmImport, accessToken);
  }

  let beforeTimestamp = swarmImport.beforeTimestamp;
  let checkinsImported = swarmImport.checkinsImported;
  const seenCheckinIds = new Set<string>();

  for (;;) {
    const page = await fetchCheckinsPage(accessToken, {
      beforeTimestamp,
      afterTimestamp: swarmImport.afterTimestamp,
    });
    const newCheckins = page.checkins.filter((checkin) => !seenCheckinIds.has(checkin.id));
    // The next page starts one second after this page's oldest checkin, so
    // checkins sharing that second are not lost; it repeats some, hence the
    // dedupe, and a page of nothing but repeats means the history is done.
    if (newCheckins.length === 0) {
      if (page.itemCount > 0 && page.checkins.length === 0) {
        console.warn(`Swarm import ${swarmImport.id}: a whole page failed to parse; stopping here`);
      }
      return;
    }
    for (const checkin of newCheckins) {
      seenCheckinIds.add(checkin.id);
    }

    checkinsImported += await writeCheckinsPage(
      swarmImport.userId,
      newCheckins,
      page.rawCheckinsById,
      categoriesById,
    );
    beforeTimestamp = Math.min(...newCheckins.map((checkin) => checkin.createdAt)) + 1;

    await database
      .update(swarmImportsTable)
      .set({ beforeTimestamp, checkinsImported })
      .where(eq(swarmImportsTable.id, swarmImport.id));
  }
}

/**
 * How many checkins this run should add: Foursquare's count of the user's
 * checkins, less the ones an earlier run already brought in. What the app's
 * progress bar is measured against.
 */
async function recordExpectedCount(swarmImport: SwarmImportRow, accessToken: string): Promise<void> {
  const self = await fetchSelf(accessToken);
  if (self.checkinCount === null) {
    return;
  }
  const [alreadyImported] = await database
    .select({ value: count() })
    .from(checkinsTable)
    .where(and(eq(checkinsTable.userId, swarmImport.userId), eq(checkinsTable.source, "swarm")));
  const checkinsExpected = Math.max(self.checkinCount - (alreadyImported?.value ?? 0), 0);
  await database
    .update(swarmImportsTable)
    .set({ checkinsExpected })
    .where(eq(swarmImportsTable.id, swarmImport.id));
}

async function upsertCategories(
  categories: FoursquareCategory[],
  categoriesById: ReadonlyMap<string, CategoryNode>,
): Promise<void> {
  if (categories.length === 0) {
    return;
  }
  await database
    .insert(foursquareCategoriesTable)
    .values(
      categories.map((category) => ({
        ...category,
        overtureCategory: overtureCategoryForFoursquareCategory(category, categoriesById),
      })),
    )
    .onConflictDoUpdate({
      target: foursquareCategoriesTable.id,
      set: {
        name: sql`excluded.name`,
        pluralName: sql`excluded.plural_name`,
        shortName: sql`excluded.short_name`,
        categoryCode: sql`excluded.category_code`,
        parentId: sql`excluded.parent_id`,
        iconPrefix: sql`excluded.icon_prefix`,
        iconSuffix: sql`excluded.icon_suffix`,
        overtureCategory: sql`excluded.overture_category`,
        updatedAt: new Date(),
      },
    });
}

/**
 * Writes one page: the Foursquare venues and the `places` rows made from
 * them first, then, with those rows' ids in hand, the checkins, each one's
 * raw payload and its photos. Returns how many checkins were new.
 */
async function writeCheckinsPage(
  userId: string,
  checkins: FoursquareCheckin[],
  rawCheckinsById: ReadonlyMap<string, unknown>,
  categoriesById: ReadonlyMap<string, CategoryNode>,
): Promise<number> {
  // A checkin with no venue (a bare shout) has no place to show; skip it.
  const withVenues = checkins.filter((checkin) => checkin.venue);
  if (withVenues.length === 0) {
    return 0;
  }

  // Checkin ids are generated here so payloads and photos can reference them
  // within the batch. A checkin imported before keeps its id, or its children
  // would point at a row that the upsert never created.
  const existing = await database
    .select({ id: checkinsTable.id, externalId: checkinsTable.externalId })
    .from(checkinsTable)
    .where(
      and(
        eq(checkinsTable.userId, userId),
        eq(checkinsTable.source, "swarm"),
        inArray(
          checkinsTable.externalId,
          withVenues.map((checkin) => checkin.id),
        ),
      ),
    );
  const existingIdByExternalId = new Map(existing.map((row) => [row.externalId, row.id]));

  const shaped = withVenues.map((checkin) =>
    toSwarmCheckinRows(
      checkin,
      userId,
      existingIdByExternalId.get(checkin.id) ?? randomUUID(),
      categoriesById,
    ),
  );
  const venuesById = new Map(shaped.map((rows) => [rows.venue.id, rows.venue]));
  const placesByVenueId = new Map(shaped.map((rows) => [rows.place.foursquareVenueId!, rows.place]));

  const [, placeRows] = await database.batch([
    database
      .insert(foursquareVenuesTable)
      .values([...venuesById.values()])
      .onConflictDoUpdate({
        target: foursquareVenuesTable.id,
        set: {
          name: sql`excluded.name`,
          address: sql`excluded.address`,
          crossStreet: sql`excluded.cross_street`,
          city: sql`excluded.city`,
          state: sql`excluded.state`,
          postalCode: sql`excluded.postal_code`,
          countryCode: sql`excluded.country_code`,
          country: sql`excluded.country`,
          formattedAddress: sql`excluded.formatted_address`,
          latitude: sql`excluded.latitude`,
          longitude: sql`excluded.longitude`,
          primaryCategoryId: sql`excluded.primary_category_id`,
          categoryIds: sql`excluded.category_ids`,
          raw: sql`excluded.raw`,
          updatedAt: new Date(),
        },
      }),
    database
      .insert(placesTable)
      .values([...placesByVenueId.values()])
      .onConflictDoUpdate({
        target: placesTable.foursquareVenueId,
        // Everything Foursquare describes is refreshed. Who may see the row
        // and whether it is retired are ours and left alone.
        set: {
          name: sql`excluded.name`,
          primaryType: sql`excluded.primary_type`,
          types: sql`excluded.types`,
          categoryName: sql`excluded.category_name`,
          addressStreet: sql`excluded.address_street`,
          addressLocality: sql`excluded.address_locality`,
          addressRegion: sql`excluded.address_region`,
          addressPostcode: sql`excluded.address_postcode`,
          addressCountry: sql`excluded.address_country`,
          latitude: sql`excluded.latitude`,
          longitude: sql`excluded.longitude`,
          updatedAt: new Date(),
        },
      })
      .returning({ id: placesTable.id, foursquareVenueId: placesTable.foursquareVenueId }),
  ]);
  const placeIdByVenueId = new Map(placeRows.map((row) => [row.foursquareVenueId, row.id]));

  const checkinRows: CheckinInsert[] = shaped.map((rows) => ({
    ...rows.checkin,
    placeId: placeIdByVenueId.get(rows.venue.id)!,
  }));
  const photos = shaped.flatMap((rows) => rows.photos);

  const statements: BatchItem<"pg">[] = [
    database
      .insert(checkinsTable)
      .values(checkinRows)
      .onConflictDoUpdate({
        target: [checkinsTable.userId, checkinsTable.source, checkinsTable.externalId],
        targetWhere: isNotNull(checkinsTable.externalId),
        // The place snapshot follows Foursquare; the message and visibility do
        // not, because once imported they can be edited here, and a resync
        // must not undo that.
        set: {
          placeId: sql`excluded.place_id`,
          placeName: sql`excluded.place_name`,
          placeAddress: sql`excluded.place_address`,
          placeLocality: sql`excluded.place_locality`,
          placeRegion: sql`excluded.place_region`,
          placeCountry: sql`excluded.place_country`,
          placePrimaryType: sql`excluded.place_primary_type`,
          placeTypes: sql`excluded.place_types`,
          placeCategoryName: sql`excluded.place_category_name`,
          latitude: sql`excluded.latitude`,
          longitude: sql`excluded.longitude`,
          timeZoneOffsetMinutes: sql`excluded.time_zone_offset_minutes`,
          updatedAt: new Date(),
        },
      }),
    database
      .insert(importedCheckinPayloadsTable)
      .values(
        shaped.map((rows) => ({
          checkinId: rows.checkin.id,
          source: "swarm" as const,
          payload: rawCheckinsById.get(rows.checkin.externalId!) ?? {},
        })),
      )
      .onConflictDoUpdate({
        target: importedCheckinPayloadsTable.checkinId,
        set: { payload: sql`excluded.payload`, fetchedAt: new Date() },
      }),
  ];
  if (photos.length > 0) {
    // A photo already imported, copied to R2 or not, is left as it is.
    statements.push(database.insert(checkinPhotosTable).values(photos).onConflictDoNothing());
  }

  await database.batch(statements as [BatchItem<"pg">, ...BatchItem<"pg">[]]);
  return shaped.length - existing.length;
}

export interface SwarmCheckinRows {
  venue: VenueInsert;
  place: PlaceInsert;
  /** Everything but the placeId, which is known once the place row exists. */
  checkin: Omit<CheckinInsert, "placeId"> & { id: string };
  photos: PhotoInsert[];
}

/**
 * Foursquare gives a state as "CA" and a country as "US"; Overture stores the
 * region as the ISO 3166-2 code "US-CA". Anything not in that shape is kept
 * as Foursquare sent it.
 */
function overtureRegion(state: string | undefined, countryCode: string | undefined): string | null {
  if (!state) {
    return null;
  }
  if (countryCode && /^[A-Z]{2}$/.test(countryCode) && /^[A-Z]{2}$/.test(state)) {
    return `${countryCode}-${state}`;
  }
  return state;
}

/**
 * Shapes one Swarm checkin into our rows: the venue as Foursquare described
 * it, the `places` row made from it, and the checkin with the same place
 * snapshot every other checkin carries, so every reader displays the two
 * alike. The Overture categories come from foursquare-category-mapping.ts;
 * `categoryName` keeps Foursquare's exact label.
 */
export function toSwarmCheckinRows(
  checkin: FoursquareCheckin,
  userId: string,
  checkinId: string,
  categoriesById: ReadonlyMap<string, CategoryNode>,
): SwarmCheckinRows {
  const venue = checkin.venue as FoursquareVenue;
  const location = venue.location ?? {};
  const primaryCategory =
    venue.categories.find((category) => category.primary) ?? venue.categories[0];

  const mappedTypes = [
    ...new Set(
      venue.categories
        .map((category) => overtureCategoryForFoursquareCategory(category, categoriesById))
        .filter((overtureCategory) => overtureCategory !== null),
    ),
  ];
  // The primary category's mapping leads; when it has none, whichever other
  // category mapped stands in rather than leaving the venue uncategorised.
  const primaryType =
    (primaryCategory ? overtureCategoryForFoursquareCategory(primaryCategory, categoriesById) : null) ??
    mappedTypes[0] ??
    null;
  const types = primaryType
    ? [primaryType, ...mappedTypes.filter((type) => type !== primaryType)]
    : mappedTypes;

  const place: PlaceInsert = {
    source: "foursquare",
    foursquareVenueId: venue.id,
    name: venue.name,
    primaryType,
    types,
    categoryName: primaryCategory?.name ?? null,
    addressStreet: location.address ?? null,
    addressLocality: location.city ?? null,
    addressRegion: overtureRegion(location.state, location.cc),
    addressPostcode: location.postalCode ?? null,
    addressCountry: location.cc?.toUpperCase() ?? null,
    latitude: location.lat ?? null,
    longitude: location.lng ?? null,
  };
  // A country on its own ("US") is not an address worth showing under a
  // checkin; Foursquare sends that much for a home with no street.
  const hasAddressLine =
    place.addressStreet || place.addressLocality || place.addressRegion || place.addressPostcode;

  return {
    venue: {
      id: venue.id,
      name: venue.name,
      address: location.address ?? null,
      crossStreet: location.crossStreet ?? null,
      city: location.city ?? null,
      state: location.state ?? null,
      postalCode: location.postalCode ?? null,
      countryCode: location.cc ?? null,
      country: location.country ?? null,
      formattedAddress: location.formattedAddress?.join(", ") || null,
      latitude: location.lat ?? null,
      longitude: location.lng ?? null,
      primaryCategoryId: primaryCategory?.id ?? null,
      categoryIds: venue.categories.map((category) => category.id),
      raw: venue,
    },
    place,
    checkin: {
      id: checkinId,
      userId,
      source: "swarm",
      externalId: checkin.id,
      placeName: venue.name,
      placeAddress: hasAddressLine
        ? formatAddress({
            addressStreet: place.addressStreet ?? null,
            addressLocality: place.addressLocality ?? null,
            addressRegion: place.addressRegion ?? null,
            addressPostcode: place.addressPostcode ?? null,
            addressCountry: place.addressCountry ?? null,
          })
        : null,
      placeLocality: place.addressLocality ?? null,
      placeRegion: place.addressRegion ?? null,
      placeCountry: place.addressCountry ?? null,
      placePrimaryType: primaryType,
      placeTypes: types.length > 0 ? types : null,
      placeCategoryName: place.categoryName ?? null,
      latitude: location.lat ?? null,
      longitude: location.lng ?? null,
      message: checkin.shout?.trim() || null,
      visibility:
        checkin.private === true || checkin.visibility === "private" ? "private" : "friends",
      timeZoneOffsetMinutes: checkin.timeZoneOffset ?? null,
      createdAt: new Date(checkin.createdAt * 1000),
    },
    photos: (checkin.photos?.items ?? []).map((photo, position) => ({
      checkinId,
      position,
      sourceUrl: photoUrl(photo),
      externalId: photo.id,
      width: photo.width ?? null,
      height: photo.height ?? null,
    })),
  };
}

/** Imported photos for this user that still need copying to R2. */
function isPendingPhotoFor(userId: string) {
  return and(
    eq(checkinsTable.userId, userId),
    isNull(checkinPhotosTable.storageKey),
    isNull(checkinPhotosTable.copyFailedAt),
  );
}

/**
 * Copies imported photos from Foursquare's CDN into R2, resized to fit
 * PHOTO_MAX_DIMENSION. Until a photo is copied it is served from its source,
 * so this phase can take as long as it needs.
 *
 * A photo the source no longer has (a 4xx) or that will not decode is marked
 * as failed and keeps its hotlink. Anything else, such as R2 being down, fails
 * the import so a later sync picks the remaining photos back up rather than
 * giving up on them.
 */
async function copyPhotos(swarmImport: SwarmImportRow): Promise<void> {
  const { userId } = swarmImport;
  const [pending] = await database
    .select({ value: count() })
    .from(checkinPhotosTable)
    .innerJoin(checkinsTable, eq(checkinsTable.id, checkinPhotosTable.checkinId))
    .where(isPendingPhotoFor(userId));
  let photosCopied = swarmImport.photosCopied;
  await database
    .update(swarmImportsTable)
    .set({ photosTotal: photosCopied + (pending?.value ?? 0) })
    .where(eq(swarmImportsTable.id, swarmImport.id));

  for (;;) {
    const batch = await database
      .select({ id: checkinPhotosTable.id, sourceUrl: checkinPhotosTable.sourceUrl })
      .from(checkinPhotosTable)
      .innerJoin(checkinsTable, eq(checkinsTable.id, checkinPhotosTable.checkinId))
      .where(isPendingPhotoFor(userId))
      .orderBy(desc(checkinsTable.createdAt), asc(checkinPhotosTable.position))
      .limit(PHOTO_BATCH_SIZE);
    if (batch.length === 0) {
      return;
    }

    for (let start = 0; start < batch.length; start += PHOTO_COPY_CONCURRENCY) {
      const results = await Promise.all(
        batch
          .slice(start, start + PHOTO_COPY_CONCURRENCY)
          .map((photo) => copyPhoto(userId, photo.id, photo.sourceUrl!)),
      );
      photosCopied += results.filter(Boolean).length;
    }

    await database
      .update(swarmImportsTable)
      .set({ photosCopied })
      .where(eq(swarmImportsTable.id, swarmImport.id));
  }
}

/**
 * True if the photo was copied, false if the source no longer has it or sent
 * something that isn't an image.
 */
async function copyPhoto(userId: string, photoId: string, sourceUrl: string): Promise<boolean> {
  const response = await fetch(sourceUrl);
  if (response.status >= 400 && response.status < 500) {
    await markPhotoCopyFailed(photoId);
    return false;
  }
  if (!response.ok) {
    throw new Error(`Photo source answered ${response.status}`);
  }

  const sourceBytes = Buffer.from(await response.arrayBuffer());
  let resized: { data: Buffer; info: OutputInfo };
  try {
    resized = await sharp(sourceBytes)
      // Honour EXIF orientation before the metadata is stripped.
      .rotate()
      .resize({
        width: PHOTO_MAX_DIMENSION,
        height: PHOTO_MAX_DIMENSION,
        fit: "inside",
        withoutEnlargement: true,
      })
      .jpeg({ quality: PHOTO_JPEG_QUALITY })
      .toBuffer({ resolveWithObject: true });
  } catch (error) {
    // Retrying won't make the bytes decode, and since pending photos are
    // copied newest first, throwing would stall every later sync on this one.
    console.warn(`Swarm photo ${photoId} could not be decoded`, error);
    await markPhotoCopyFailed(photoId);
    return false;
  }
  const { data, info } = resized;

  const storageKey = `checkin-photos/${userId}/${photoId}.jpg`;
  await putJpegObject(storageKey, data);
  await database
    .update(checkinPhotosTable)
    .set({ storageKey, width: info.width, height: info.height })
    .where(eq(checkinPhotosTable.id, photoId));
  return true;
}

/** Gives up on copying a photo; it keeps serving its source URL. */
async function markPhotoCopyFailed(photoId: string): Promise<void> {
  await database
    .update(checkinPhotosTable)
    .set({ copyFailedAt: new Date() })
    .where(eq(checkinPhotosTable.id, photoId));
}
