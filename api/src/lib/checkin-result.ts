import type { checkins } from "../db/schema.js";

type CheckinRow = typeof checkins.$inferSelect;

export function toCheckinResult(checkin: CheckinRow) {
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
    createdAt: checkin.createdAt,
    updatedAt: checkin.updatedAt,
  };
}
