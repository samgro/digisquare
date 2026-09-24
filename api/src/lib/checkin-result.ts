import type { VisibleCheckin } from "./checkin-queries.js";

// Takes only a VisibleCheckin, so every checkin sent to a client has come
// through the visibility rule in checkin-queries.ts.
export function toCheckinResult(checkin: VisibleCheckin) {
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
    createdAt: checkin.createdAt,
    updatedAt: checkin.updatedAt,
  };
}
