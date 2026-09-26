/**
 * Maps a place feature from the Overture Maps places theme, as the
 * `overturemaps` CLI writes it to GeoJSON, onto a `places` row.
 *
 * Two generations of the category property are accepted: `taxonomy`
 * (`primary`, `hierarchy`, `alternates`; current schema) and the older
 * `categories` (`primary`, `alternate`). Everything else has been stable:
 * `names.primary`, `addresses[]`, `confidence`, `websites[]`, `phones[]`.
 */

import type { places } from "../db/schema.js";

export type OverturePlaceInsert = typeof places.$inferInsert & { source: "overture" };

interface OvertureAddress {
  freeform?: string | null;
  locality?: string | null;
  region?: string | null;
  postcode?: string | null;
  country?: string | null;
}

export interface OverturePlaceFeature {
  id?: string;
  type?: string;
  geometry?: { type?: string; coordinates?: unknown } | null;
  properties?: {
    names?: { primary?: string | null } | null;
    taxonomy?: {
      primary?: string | null;
      hierarchy?: (string | null)[] | null;
      alternates?: (string | null)[] | null;
    } | null;
    categories?: {
      primary?: string | null;
      alternate?: (string | null)[] | null;
    } | null;
    confidence?: number | null;
    addresses?: (OvertureAddress | null)[] | null;
    websites?: (string | null)[] | null;
    phones?: (string | null)[] | null;
    operating_status?: string | null;
  } | null;
}

export type SkipReason =
  | "missing_id"
  | "missing_name"
  | "missing_point"
  | "permanently_closed";

export type ParsedOverturePlace =
  | { row: OverturePlaceInsert; skipped?: undefined }
  | { row?: undefined; skipped: SkipReason };

const CATEGORY_CODE = /^[a-z0-9]+(_[a-z0-9]+)*$/;

function nonEmpty(value: unknown): string | null {
  if (typeof value !== "string") {
    return null;
  }
  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : null;
}

function categoryCodes(values: (string | null)[] | null | undefined): string[] {
  return (values ?? [])
    .map(nonEmpty)
    .filter((value): value is string => value !== null && CATEGORY_CODE.test(value));
}

/**
 * The primary category first, then the alternates, without repeats. Nothing
 * from `hierarchy`: a coffee shop's ancestors (`eat_and_drink`) would match
 * no footprint or icon and only pad the list.
 */
export function overtureCategories(feature: OverturePlaceFeature): {
  primaryType: string | null;
  types: string[];
} {
  const properties = feature.properties ?? {};
  const primaryType =
    categoryCodes([properties.taxonomy?.primary ?? null])[0] ??
    categoryCodes([properties.categories?.primary ?? null])[0] ??
    null;
  const alternates = [
    ...categoryCodes(properties.taxonomy?.alternates),
    ...categoryCodes(properties.categories?.alternate),
  ];
  const types: string[] = [];
  for (const type of [primaryType, ...alternates]) {
    if (type !== null && !types.includes(type)) {
      types.push(type);
    }
  }
  return { primaryType, types };
}

function pointCoordinates(feature: OverturePlaceFeature): { latitude: number; longitude: number } | null {
  const geometry = feature.geometry;
  if (!geometry || geometry.type !== "Point" || !Array.isArray(geometry.coordinates)) {
    return null;
  }
  // GeoJSON order is longitude, latitude.
  const [longitude, latitude] = geometry.coordinates as unknown[];
  if (
    typeof latitude !== "number" ||
    typeof longitude !== "number" ||
    !Number.isFinite(latitude) ||
    !Number.isFinite(longitude) ||
    Math.abs(latitude) > 90 ||
    Math.abs(longitude) > 180
  ) {
    return null;
  }
  return { latitude, longitude };
}

export function parseOverturePlace(feature: OverturePlaceFeature): ParsedOverturePlace {
  const overtureId = nonEmpty(feature.id);
  if (overtureId === null) {
    return { skipped: "missing_id" };
  }
  const properties = feature.properties ?? {};
  const name = nonEmpty(properties.names?.primary);
  if (name === null) {
    return { skipped: "missing_name" };
  }
  const coordinates = pointCoordinates(feature);
  if (coordinates === null) {
    return { skipped: "missing_point" };
  }
  // A closed venue is not somewhere to check in; a temporarily closed one
  // still is (the user may be at its reopening).
  if (properties.operating_status === "permanently_closed") {
    return { skipped: "permanently_closed" };
  }

  const address = (properties.addresses ?? []).find((candidate) => candidate !== null) ?? {};
  const confidence =
    typeof properties.confidence === "number" && Number.isFinite(properties.confidence)
      ? Math.min(Math.max(properties.confidence, 0), 1)
      : null;

  return {
    row: {
      source: "overture",
      overtureId,
      name,
      ...overtureCategories(feature),
      addressStreet: nonEmpty(address.freeform),
      addressLocality: nonEmpty(address.locality),
      addressRegion: nonEmpty(address.region),
      addressPostcode: nonEmpty(address.postcode),
      addressCountry: nonEmpty(address.country)?.toUpperCase() ?? null,
      latitude: coordinates.latitude,
      longitude: coordinates.longitude,
      confidence,
      website: nonEmpty((properties.websites ?? [])[0]),
      phone: nonEmpty((properties.phones ?? [])[0]),
    },
  };
}
