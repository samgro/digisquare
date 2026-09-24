/**
 * Picks the venue grounds out of Overture's base theme. `land_use` carries
 * parks, campuses, golf courses, stadium grounds, zoos and campgrounds;
 * `infrastructure` carries airports. Each is a named polygon, which is the
 * extent a place is missing: Overture places are points.
 *
 * A feature becomes an extent only when its class maps to a family, and a
 * family lists the place categories it may attach to, so a marine
 * sanctuary's 5,000 km2 polygon never becomes a cafe's grounds.
 */

import type { WkbGeometry, WkbPosition } from "./wkb.js";

export type ExtentFamily =
  | "airport"
  | "park"
  | "stadium"
  | "college_university"
  | "golf_course"
  | "zoo"
  | "amusement_park"
  | "ski"
  | "campground"
  | "marina"
  | "hospital";

export interface OvertureExtentFeature {
  id?: string;
  geometry?: { type?: string; coordinates?: unknown } | null;
  properties?: {
    subtype?: string | null;
    class?: string | null;
    names?: { primary?: string | null } | null;
  } | null;
}

export interface ParsedExtent {
  overtureId: string;
  name: string;
  family: ExtentFamily;
  /** GeoJSON MultiPolygon coordinates: polygons, rings, positions. */
  polygons: WkbPosition[][][];
}

/** `subtype:class` pairs, or bare classes, that count as venue grounds. */
const FAMILY_BY_CLASS: Record<string, ExtentFamily> = {
  "airport:airport": "airport",
  "airport:international_airport": "airport",
  "airport:airstrip": "airport",
  "park:park": "park",
  "park:national_park": "park",
  "park:state_park": "park",
  "park:dog_park": "park",
  "protected:national_park": "park",
  "protected:nature_reserve": "park",
  "recreation:stadium": "stadium",
  "education:university": "college_university",
  "education:college": "college_university",
  "golf:golf_course": "golf_course",
  "entertainment:zoo": "zoo",
  "entertainment:theme_park": "amusement_park",
  "campground:camp_site": "campground",
  "campground:campground": "campground",
  "transportation:marina": "marina",
  "medical:hospital": "hospital",
};

/** Subtypes whose every class belongs to one family. */
const FAMILY_BY_SUBTYPE: Record<string, ExtentFamily> = {
  winter_sports: "ski",
};

/**
 * Place categories each family may become the grounds of. The primary
 * category is what is matched (see extent-matching.ts), with the
 * `_stadium` and `_airports` suffixes for Overture's specific variants.
 */
export const PLACE_CATEGORIES_BY_FAMILY: Record<ExtentFamily, readonly string[]> = {
  airport: ["airport", "airport_terminal", "major_airports", "domestic_airports"],
  park: ["park", "national_park", "state_park", "dog_park", "nature_reserve", "garden", "botanical_garden"],
  stadium: ["stadium_arena"],
  college_university: ["college_university"],
  golf_course: ["golf_course"],
  zoo: ["zoo", "petting_zoo"],
  amusement_park: ["amusement_park"],
  ski: ["ski_resort", "ski_area"],
  campground: ["campground"],
  marina: ["marina"],
  hospital: ["hospital"],
};

export const CATEGORY_SUFFIXES_BY_FAMILY: Partial<Record<ExtentFamily, readonly string[]>> = {
  stadium: ["_stadium"],
  airport: ["_airports"],
};

export function extentFamily(subtype: string | null | undefined, className: string | null | undefined): ExtentFamily | null {
  if (subtype && FAMILY_BY_SUBTYPE[subtype]) {
    return FAMILY_BY_SUBTYPE[subtype];
  }
  if (!subtype || !className) {
    return null;
  }
  return FAMILY_BY_CLASS[`${subtype}:${className}`] ?? null;
}

/** Whether a place category can carry an extent of this family. */
export function familyAcceptsCategory(family: ExtentFamily, category: string): boolean {
  if (PLACE_CATEGORIES_BY_FAMILY[family].includes(category)) {
    return true;
  }
  return (CATEGORY_SUFFIXES_BY_FAMILY[family] ?? []).some((suffix) => category.endsWith(suffix));
}

function nonEmpty(value: unknown): string | null {
  if (typeof value !== "string") {
    return null;
  }
  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : null;
}

function polygonsOf(geometry: OvertureExtentFeature["geometry"]): WkbPosition[][][] | null {
  if (!geometry || !Array.isArray(geometry.coordinates)) {
    return null;
  }
  if (geometry.type === "Polygon") {
    return [geometry.coordinates as WkbPosition[][]];
  }
  if (geometry.type === "MultiPolygon") {
    return geometry.coordinates as WkbPosition[][][];
  }
  return null;
}

/**
 * Null for anything that is not named venue grounds: a taxiway, a lawn, a
 * retail lot, a marine sanctuary. Names are required because they are what
 * ties the polygon to the place.
 */
export function parseOvertureExtent(feature: OvertureExtentFeature): ParsedExtent | null {
  const overtureId = nonEmpty(feature.id);
  const properties = feature.properties ?? {};
  const name = nonEmpty(properties.names?.primary);
  const family = extentFamily(properties.subtype, properties.class);
  if (overtureId === null || name === null || family === null) {
    return null;
  }
  const polygons = polygonsOf(feature.geometry);
  if (polygons === null || polygons.length === 0 || polygons.some((rings) => rings.length === 0)) {
    return null;
  }
  return { overtureId, name, family, polygons };
}

/** Lower-cased, punctuation-free, with a leading "the" dropped. */
export function normalizedName(name: string): string {
  return name
    .toLowerCase()
    .replace(/['\u2019]/g, "")
    .replace(/[^\p{L}\p{N}\s]/gu, " ")
    .replace(/\s+/g, " ")
    .trim()
    .replace(/^the /, "");
}

/**
 * Whether a polygon's name and a place's name are the same venue: equal
 * once normalized, or one contains the other ("Golden Gate Park" and
 * "Golden Gate Park Polo Field and Stadium" are not, because the shorter
 * one is the container; the check is only used to break ties among places
 * already inside the polygon).
 */
export function namesMatch(extentName: string, placeName: string): boolean {
  const first = normalizedName(extentName);
  const second = normalizedName(placeName);
  if (first.length === 0 || second.length === 0) {
    return false;
  }
  return first === second || first.includes(second) || second.includes(first);
}

/** Point-in-polygon by ray casting, holes respected. */
export function polygonsContain(polygons: WkbPosition[][][], longitude: number, latitude: number): boolean {
  return polygons.some(([outer, ...holes]) => {
    if (!outer || !ringContains(outer, longitude, latitude)) {
      return false;
    }
    return !holes.some((hole) => ringContains(hole, longitude, latitude));
  });
}

function ringContains(ring: WkbPosition[], longitude: number, latitude: number): boolean {
  let inside = false;
  for (let index = 0, previous = ring.length - 1; index < ring.length; previous = index, index += 1) {
    const [currentX, currentY] = ring[index];
    const [previousX, previousY] = ring[previous];
    const crosses = currentY > latitude !== previousY > latitude;
    if (crosses) {
      const intersectionX = ((previousX - currentX) * (latitude - currentY)) / (previousY - currentY) + currentX;
      if (longitude < intersectionX) {
        inside = !inside;
      }
    }
  }
  return inside;
}

export function extentFromWkbGeometry(geometry: WkbGeometry): OvertureExtentFeature["geometry"] {
  return geometry.type === "Polygon" || geometry.type === "MultiPolygon" ? geometry : null;
}
