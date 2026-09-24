import type { checkins } from "../db/schema.js";
import type { CheckinSocial } from "./checkin-social.js";

type CheckinRow = typeof checkins.$inferSelect;

/**
 * A checkin as every route returns it. The social counts are always present
 * so the client can decode one shape; a route that has not loaded them (a
 * checkin that was just created has none) leaves them at zero.
 */
export function toCheckinResult(checkin: CheckinRow, social?: Partial<CheckinSocial>) {
  return {
    id: checkin.id,
    userId: checkin.userId,
    googlePlaceId: checkin.googlePlaceId,
    placeName: checkin.placeName,
    placeAddress: checkin.placeAddress,
    placePrimaryType: checkin.placePrimaryType,
    placeTypes: checkin.placeTypes,
    location:
      checkin.latitude !== null && checkin.longitude !== null
        ? { latitude: checkin.latitude, longitude: checkin.longitude }
        : null,
    message: checkin.message,
    visibility: checkin.visibility,
    source: checkin.source,
    likeCount: social?.likeCount ?? 0,
    commentCount: social?.commentCount ?? 0,
    likedByMe: social?.likedByMe ?? false,
    createdAt: checkin.createdAt,
    updatedAt: checkin.updatedAt,
  };
}
