import { asc, inArray } from "drizzle-orm";
import { database } from "../db/index.js";
import { checkinPhotos as checkinPhotosTable, type checkins } from "../db/schema.js";
import type { CheckinSocial } from "./checkin-social.js";
import { publicUrlFor } from "./r2.js";

type CheckinRow = typeof checkins.$inferSelect;
type CheckinPhotoRow = typeof checkinPhotosTable.$inferSelect;

export type CheckinPhotoResult = ReturnType<typeof toCheckinPhotoResult>;

/**
 * An imported photo is served from its source until the background copy to R2
 * lands, then from R2. Clients only ever see the resulting url.
 */
export function toCheckinPhotoResult(photo: CheckinPhotoRow) {
  return {
    id: photo.id,
    url: photo.storageKey ? publicUrlFor(photo.storageKey) : photo.sourceUrl!,
    width: photo.width,
    height: photo.height,
  };
}

/**
 * A checkin as every route returns it. The social counts are always present
 * so the client can decode one shape; a route that has not loaded them (a
 * checkin that was just created has none) leaves them at zero. Photos are
 * loaded per page with loadPhotosByCheckinId.
 */
export function toCheckinResult(
  checkin: CheckinRow,
  social?: Partial<CheckinSocial>,
  photos: CheckinPhotoResult[] = [],
) {
  return {
    id: checkin.id,
    userId: checkin.userId,
    placeId: checkin.placeId,
    placeName: checkin.placeName,
    placeAddress: checkin.placeAddress,
    placeLocality: checkin.placeLocality,
    placeRegion: checkin.placeRegion,
    placeCountry: checkin.placeCountry,
    placePrimaryType: checkin.placePrimaryType,
    placeTypes: checkin.placeTypes,
    placeCategoryName: checkin.placeCategoryName,
    location:
      checkin.latitude !== null && checkin.longitude !== null
        ? { latitude: checkin.latitude, longitude: checkin.longitude }
        : null,
    message: checkin.message,
    visibility: checkin.visibility,
    source: checkin.source,
    photos,
    timeZoneOffsetMinutes: checkin.timeZoneOffsetMinutes,
    likeCount: social?.likeCount ?? 0,
    commentCount: social?.commentCount ?? 0,
    likedByMe: social?.likedByMe ?? false,
    createdAt: checkin.createdAt,
    updatedAt: checkin.updatedAt,
  };
}

/**
 * The photos for a page of checkins in one query, grouped by checkin and in
 * display order. A checkin with no photos is simply absent from the map.
 */
export async function loadPhotosByCheckinId(
  checkinIds: string[],
): Promise<Map<string, CheckinPhotoResult[]>> {
  const photosByCheckinId = new Map<string, CheckinPhotoResult[]>();
  if (checkinIds.length === 0) {
    return photosByCheckinId;
  }

  const rows = await database
    .select()
    .from(checkinPhotosTable)
    .where(inArray(checkinPhotosTable.checkinId, checkinIds))
    .orderBy(asc(checkinPhotosTable.checkinId), asc(checkinPhotosTable.position));

  for (const row of rows) {
    const photos = photosByCheckinId.get(row.checkinId) ?? [];
    photos.push(toCheckinPhotoResult(row));
    photosByCheckinId.set(row.checkinId, photos);
  }
  return photosByCheckinId;
}
