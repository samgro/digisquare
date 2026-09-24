import type { PlaceCandidate } from "./places-search.js";

export interface PlaceExtentResult {
  boundingBox: { south: number; west: number; north: number; east: number };
  /** Outer rings only, as [longitude, latitude] pairs, simplified to about 5 m. */
  rings: [number, number][][];
  areaSquareMeters: number;
}

export interface PlaceResult {
  id: string;
  source: "overture" | "user" | "google";
  name: string;
  /** "450 10th St, San Francisco, CA 94103, US", or null with no parts. */
  address: string | null;
  street: string | null;
  locality: string | null;
  region: string | null;
  postcode: string | null;
  country: string | null;
  location: { latitude: number; longitude: number } | null;
  /** The venue's grounds, when Overture's base theme has a polygon for it. */
  extent: PlaceExtentResult | null;
  /**
   * Meters from the searched fix to the venue: to the edge of its grounds
   * (zero inside) when it has an extent, else to its pin. Null when the
   * result did not come from a search around a fix.
   */
  distanceMeters: number | null;
  /** Overture category codes, the primary one first. */
  types: string[];
  primaryType: string | null;
  /** Checkins here from everyone, the app's stand-in for popularity. */
  checkinCount: number;
  /** Only its creator and their friends can find it. */
  isPrivate: boolean;
  /** Dropped by a newer Overture release; kept for the checkins that point at it. */
  retired: boolean;
  website: string | null;
  phone: string | null;
}

interface AddressParts {
  addressStreet: string | null;
  addressLocality: string | null;
  addressRegion: string | null;
  addressPostcode: string | null;
  addressCountry: string | null;
}

/** "US-CA" reads as "CA" in an address line; anything else is kept as-is. */
export function displayRegion(region: string | null): string | null {
  if (region === null) {
    return null;
  }
  const match = /^[A-Z]{2}-(.+)$/.exec(region);
  return match ? match[1] : region;
}

/**
 * One line in the shape Google used to send, which is also what the app's
 * timeline snapshot stores: street, locality, region and postcode, country.
 */
export function formatAddress(parts: AddressParts): string | null {
  const regionAndPostcode = [displayRegion(parts.addressRegion), parts.addressPostcode]
    .filter((part): part is string => part !== null)
    .join(" ");
  const components = [
    parts.addressStreet,
    parts.addressLocality,
    regionAndPostcode || null,
    parts.addressCountry,
  ].filter((part): part is string => part !== null && part.length > 0);
  return components.length > 0 ? components.join(", ") : null;
}

interface GeoJsonMultiPolygon {
  type: "MultiPolygon";
  coordinates: [number, number][][][];
}

interface GeoJsonPolygon {
  type: "Polygon";
  coordinates: [number, number][][];
}

/**
 * The extent as the search selected it: PostGIS's GeoJSON for the
 * simplified polygon (a string), its area, and its bounding box corners.
 */
export function toExtentResult(candidate: PlaceCandidate): PlaceExtentResult | null {
  if (!candidate.extentGeoJson || candidate.extentAreaSquareMeters === null) {
    return null;
  }
  if (
    candidate.extentSouth === null ||
    candidate.extentWest === null ||
    candidate.extentNorth === null ||
    candidate.extentEast === null
  ) {
    return null;
  }
  const geometry = JSON.parse(candidate.extentGeoJson) as GeoJsonMultiPolygon | GeoJsonPolygon;
  const polygons = geometry.type === "Polygon" ? [geometry.coordinates] : geometry.coordinates;
  return {
    boundingBox: {
      south: candidate.extentSouth,
      west: candidate.extentWest,
      north: candidate.extentNorth,
      east: candidate.extentEast,
    },
    rings: polygons.map((rings) => rings[0]).filter((ring) => ring !== undefined),
    areaSquareMeters: candidate.extentAreaSquareMeters,
  };
}

export function toPlaceResult(place: PlaceCandidate): PlaceResult {
  return {
    id: place.id,
    source: place.source,
    name: place.name,
    address: formatAddress(place),
    street: place.addressStreet,
    locality: place.addressLocality,
    region: place.addressRegion,
    postcode: place.addressPostcode,
    country: place.addressCountry,
    location:
      place.latitude !== null && place.longitude !== null
        ? { latitude: place.latitude, longitude: place.longitude }
        : null,
    extent: toExtentResult(place),
    distanceMeters: place.distanceMeters ?? null,
    types: place.types,
    primaryType: place.primaryType,
    checkinCount: place.checkinCount,
    isPrivate: place.isPrivate,
    retired: place.retiredAt !== null,
    website: place.website,
    phone: place.phone,
  };
}
