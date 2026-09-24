import type { PlaceCandidate } from "./places-search.js";

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
  /** Overture category codes, the primary one first. */
  types: string[];
  primaryType: string | null;
  /** Checkins here from everyone, the app's stand-in for popularity. */
  checkinCount: number;
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
    types: place.types,
    primaryType: place.primaryType,
    checkinCount: place.checkinCount,
    website: place.website,
    phone: place.phone,
  };
}
