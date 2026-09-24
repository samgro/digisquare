/**
 * Attaches base-theme polygons to the places they are the grounds of.
 *
 * For each polygon: the candidate places are those whose pin is inside it
 * and whose primary category the polygon's family accepts (an `airport`
 * polygon may become an `airport` place's grounds, never a cafe's). Among
 * several candidates, a name match wins, then the one nearest the polygon's
 * centroid. A place that already holds a larger extent keeps it, so the
 * "Golden Gate Park Polo Field" stadium polygon never replaces the park's.
 */

import { sql } from "drizzle-orm";
import { database } from "../db/index.js";
import { places } from "../db/schema.js";
import {
  CATEGORY_SUFFIXES_BY_FAMILY,
  namesMatch,
  PLACE_CATEGORIES_BY_FAMILY,
  type ParsedExtent,
} from "./overture-extents.js";

interface CandidateRow {
  id: string;
  name: string;
  primaryType: string | null;
  extentAreaSquareMeters: number | null;
  centroidDistanceMeters: number;
}

function geoJsonOf(extent: ParsedExtent): string {
  return JSON.stringify({ type: "MultiPolygon", coordinates: extent.polygons });
}

function categoryPredicate(extent: ParsedExtent) {
  const exact = PLACE_CATEGORIES_BY_FAMILY[extent.family];
  const suffixes = CATEGORY_SUFFIXES_BY_FAMILY[extent.family] ?? [];
  const conditions = [
    sql`${places.primaryType} = any(ARRAY[${sql.join(exact.map((category) => sql`${category}`), sql`, `)}]::text[])`,
    ...suffixes.map((suffix) => sql`${places.primaryType} like ${`%${suffix}`}`),
  ];
  return sql.join(conditions, sql` or `);
}

/** Which place, if any, `extent` is the grounds of. */
export async function findPlaceForExtent(extent: ParsedExtent): Promise<CandidateRow | null> {
  const geometry = sql`ST_SetSRID(ST_GeomFromGeoJSON(${geoJsonOf(extent)}), 4326)`;
  const candidates = (await database.execute(sql`
    select ${places.id} as id, ${places.name} as name, ${places.primaryType} as "primaryType",
           ${places.extentAreaSquareMeters} as "extentAreaSquareMeters",
           ST_Distance(${places.location}::geography, ST_Centroid(${geometry})::geography) as "centroidDistanceMeters"
    from ${places}
    where ${places.source} = 'overture'
      and ${places.retiredAt} is null
      and ${places.location} is not null
      and ST_Contains(${geometry}, ${places.location})
      and (${categoryPredicate(extent)})
    order by "centroidDistanceMeters"
    limit 50
  `)).rows as unknown as CandidateRow[];
  if (candidates.length === 0) {
    return null;
  }
  return candidates.find((candidate) => namesMatch(extent.name, candidate.name)) ?? candidates[0];
}

export interface ExtentAttachment {
  extent: ParsedExtent;
  placeId: string;
  placeName: string;
}

/**
 * Attaches every extent that has a place, largest polygons first so a
 * container is settled before its parts, and returns what was attached.
 */
export async function attachExtents(extents: ParsedExtent[]): Promise<ExtentAttachment[]> {
  const attachments: ExtentAttachment[] = [];
  for (const extent of extents) {
    const place = await findPlaceForExtent(extent);
    if (!place) {
      continue;
    }
    const geometry = sql`ST_Multi(ST_SetSRID(ST_GeomFromGeoJSON(${geoJsonOf(extent)}), 4326))`;
    // Only replace an existing extent when this one is the same feature
    // (a refresh) or larger (a park replacing a garden inside it).
    const updated = await database.execute(sql`
      update ${places}
      set extent = ${geometry},
          extent_overture_id = ${extent.overtureId},
          extent_area_square_meters = ST_Area(${geometry}::geography),
          updated_at = now()
      where id = ${place.id}
        and (extent is null
             or extent_overture_id = ${extent.overtureId}
             or coalesce(extent_area_square_meters, 0) < ST_Area(${geometry}::geography))
      returning id
    `);
    if (updated.rows.length > 0) {
      attachments.push({ extent, placeId: place.id, placeName: place.name });
    }
  }
  return attachments;
}
