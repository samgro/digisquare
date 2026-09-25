/**
 * Attaches base-theme polygons to the places they are the grounds of.
 *
 * For each polygon: the candidate places are those whose pin is inside it
 * and whose primary category the polygon's family accepts (an `airport`
 * polygon may become an `airport` place's grounds, never a cafe's). Among
 * several candidates, a name match wins, then the one nearest the polygon's
 * centroid. A place that already holds a larger extent keeps it, so the
 * "Golden Gate Park Polo Field" stadium polygon never replaces the park's.
 *
 * The polygons go to Postgres in chunks: one query finds every chunk
 * member's candidates at once, the choice is made here (the name matching
 * is Unicode-aware JavaScript), and one update writes the winners. Each
 * chunk is two round trips rather than two per polygon.
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

/**
 * Polygons per round trip. Each polygon's coordinates travel in the request
 * twice (to find candidates, then to write the winner), and a park outline
 * can run to tens of kilobytes, so this stays well under a megabyte.
 */
export const EXTENT_CHUNK_SIZE = 50;

/** How many places inside a polygon are considered, nearest the centroid first. */
const CANDIDATE_LIMIT = 50;

interface CandidateRow {
  extentIndex: number;
  id: string;
  name: string;
  centroidDistanceMeters: number;
  areaSquareMeters: number;
}

interface WinnerRow {
  id: string;
  extentOvertureId: string;
}

export interface ExtentAttachment {
  extent: ParsedExtent;
  placeId: string;
  placeName: string;
}

export interface AttachProgress {
  /** Polygons looked at so far, whether or not they found a place. */
  matched: number;
  total: number;
  attached: number;
}

function geoJsonOf(extent: ParsedExtent): string {
  return JSON.stringify({ type: "MultiPolygon", coordinates: extent.polygons });
}

/**
 * The candidates for every polygon in the chunk, grouped by polygon in
 * input order and nearest the centroid first within each.
 */
async function findCandidates(chunk: ParsedExtent[]): Promise<CandidateRow[][]> {
  const payload = JSON.stringify(
    chunk.map((extent, index) => ({
      index,
      geometry: geoJsonOf(extent),
      categories: PLACE_CATEGORIES_BY_FAMILY[extent.family],
      suffixes: CATEGORY_SUFFIXES_BY_FAMILY[extent.family] ?? [],
    })),
  );
  const result = await database.execute(sql`
    with extent as (
      select (element->>'index')::int as extent_index,
             ST_SetSRID(ST_GeomFromGeoJSON(element->>'geometry'), 4326) as geometry,
             array(select jsonb_array_elements_text(element->'categories')) as categories,
             array(select jsonb_array_elements_text(element->'suffixes')) as suffixes
      from jsonb_array_elements(${payload}::jsonb) as element
    )
    select extent.extent_index as "extentIndex",
           candidate.id,
           candidate.name,
           candidate."centroidDistanceMeters",
           ST_Area(extent.geometry::geography) as "areaSquareMeters"
    from extent
    cross join lateral (
      select ${places.id} as id, ${places.name} as name,
             ST_Distance(${places.location}::geography, ST_Centroid(extent.geometry)::geography) as "centroidDistanceMeters"
      from ${places}
      where ${places.source} = 'overture'
        and ${places.retiredAt} is null
        and ${places.location} is not null
        and ST_Contains(extent.geometry, ${places.location})
        and (${places.primaryType} = any(extent.categories)
             or exists (select 1 from unnest(extent.suffixes) as suffix where ${places.primaryType} like '%' || suffix))
      order by "centroidDistanceMeters"
      limit ${CANDIDATE_LIMIT}
    ) as candidate
    order by extent.extent_index, candidate."centroidDistanceMeters"
  `);
  const grouped: CandidateRow[][] = chunk.map(() => []);
  for (const row of result.rows as unknown as CandidateRow[]) {
    grouped[row.extentIndex].push(row);
  }
  return grouped;
}

/** Which of its candidates, if any, a polygon is the grounds of. */
function choosePlace(extent: ParsedExtent, candidates: CandidateRow[]): CandidateRow | null {
  if (candidates.length === 0) {
    return null;
  }
  return candidates.find((candidate) => namesMatch(extent.name, candidate.name)) ?? candidates[0];
}

interface Choice {
  extent: ParsedExtent;
  place: CandidateRow;
}

/**
 * Writes each chosen polygon onto its place. When several polygons chose
 * the same place, the one refreshing the extent already there wins, else
 * the largest; and an existing extent is only replaced by the same feature
 * (a refresh) or a larger one (a park replacing a garden inside it).
 */
async function writeChoices(choices: Choice[]): Promise<WinnerRow[]> {
  const payload = JSON.stringify(
    choices.map(({ extent, place }) => ({
      place_id: place.id,
      overture_id: extent.overtureId,
      geometry: geoJsonOf(extent),
      area_square_meters: place.areaSquareMeters,
    })),
  );
  const result = await database.execute(sql`
    with chosen as (
      select distinct on (choice.place_id) choice.*
      from jsonb_to_recordset(${payload}::jsonb)
             as choice(place_id uuid, overture_id text, geometry text, area_square_meters double precision)
      join ${places} as current on current.id = choice.place_id
      order by choice.place_id,
               (choice.overture_id = current.extent_overture_id) desc nulls last,
               choice.area_square_meters desc
    )
    update ${places}
    set extent = ST_Multi(ST_SetSRID(ST_GeomFromGeoJSON(chosen.geometry), 4326)),
        extent_overture_id = chosen.overture_id,
        extent_area_square_meters = chosen.area_square_meters,
        updated_at = now()
    from chosen
    where ${places.id} = chosen.place_id
      and (${places.extent} is null
           or ${places.extentOvertureId} = chosen.overture_id
           or coalesce(${places.extentAreaSquareMeters}, 0) < chosen.area_square_meters)
    returning ${places.id} as id, chosen.overture_id as "extentOvertureId"
  `);
  return result.rows as unknown as WinnerRow[];
}

/**
 * Attaches every extent that has a place and returns what was attached.
 * `onProgress` is called after each chunk, so a long run can be logged.
 */
export async function attachExtents(
  extents: ParsedExtent[],
  onProgress: (progress: AttachProgress) => void = () => {},
): Promise<ExtentAttachment[]> {
  const attachments: ExtentAttachment[] = [];
  for (let start = 0; start < extents.length; start += EXTENT_CHUNK_SIZE) {
    const chunk = extents.slice(start, start + EXTENT_CHUNK_SIZE);
    const candidatesByExtent = await findCandidates(chunk);
    const choices: Choice[] = [];
    for (const [index, extent] of chunk.entries()) {
      const place = choosePlace(extent, candidatesByExtent[index]);
      if (place) {
        choices.push({ extent, place });
      }
    }
    if (choices.length > 0) {
      const winners = await writeChoices(choices);
      for (const winner of winners) {
        const choice = choices.find(
          ({ extent, place }) => place.id === winner.id && extent.overtureId === winner.extentOvertureId,
        );
        if (choice) {
          attachments.push({ extent: choice.extent, placeId: choice.place.id, placeName: choice.place.name });
        }
      }
    }
    onProgress({ matched: Math.min(start + chunk.length, extents.length), total: extents.length, attached: attachments.length });
  }
  return attachments;
}
