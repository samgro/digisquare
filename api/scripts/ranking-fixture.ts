/**
 * Builds a `fixtures/ranking/<name>.json` file from a scenario definition and
 * the raw Google responses. Everything derived (the merged `/places` output,
 * place keys, synthesized histories) is computed here so that the recorder and
 * the tests agree by construction, and so a re-record is reproducible.
 */

import { mergeNearbyResults, type GooglePlace, type PlacesSearchResponse } from "../src/lib/google-places.js";
import { toResult, type PlaceResult } from "../src/routes/places.js";
import type { HistoryTemplate, RankingScenarioDefinition } from "./ranking-scenarios.js";

export const RANKING_FIXTURE_SCHEMA_VERSION = 1;

export interface RecordedSearch {
  request: unknown;
  response: PlacesSearchResponse;
}

export interface RecordedGoogleData {
  /** Absent when the recorder skipped the distance search. */
  distance?: RecordedSearch;
  popularity: RecordedSearch;
}

export interface FixtureHistoryEntry {
  googlePlaceId: string;
  createdAt: string;
  placeName: string;
  placeAddress: string | null;
  placePrimaryType: string | null;
  placeTypes: string[];
  location: { latitude: number; longitude: number } | null;
}

export interface RankingFixtureCase {
  name: string;
  now: string;
  horizontalAccuracy: number;
  fixAgeSeconds: number;
  history: string;
  expect: {
    top?: string;
    suggested?: string | null;
    rankedAbove?: [string, string][];
  };
}

export interface RankingFixture {
  schemaVersion: number;
  name: string;
  description: string;
  /** Null while the Google data is hand-authored rather than recorded. */
  recordedAt: string | null;
  timeZone: string;
  fix: { latitude: number; longitude: number; horizontalAccuracy: number };
  google: RecordedGoogleData;
  /** Exactly what `GET /places` returns for the recorded responses. */
  places: PlaceResult[];
  placeKeys: Record<string, string>;
  histories: Record<string, FixtureHistoryEntry[]>;
  cases: RankingFixtureCase[];
}

const METERS_PER_DEGREE_LATITUDE = 111_320;

export function offsetCoordinate(
  origin: { latitude: number; longitude: number },
  offsetMeters: { north: number; east: number },
): { latitude: number; longitude: number } {
  const latitude = origin.latitude + offsetMeters.north / METERS_PER_DEGREE_LATITUDE;
  const metersPerDegreeLongitude =
    METERS_PER_DEGREE_LATITUDE * Math.cos((origin.latitude * Math.PI) / 180);
  const longitude = origin.longitude + offsetMeters.east / metersPerDegreeLongitude;
  return { latitude: roundCoordinate(latitude), longitude: roundCoordinate(longitude) };
}

function roundCoordinate(value: number): number {
  return Math.round(value * 1e6) / 1e6;
}

export function resolvePlaceKeys(
  definition: RankingScenarioDefinition,
  places: PlaceResult[],
): Record<string, string> {
  const resolved: Record<string, string> = {};
  const problems: string[] = [];
  for (const [key, matcher] of Object.entries(definition.placeKeys)) {
    const { name: nameFragment, primaryType } =
      typeof matcher === "string" ? { name: matcher, primaryType: undefined } : matcher;
    const needle = nameFragment.toLowerCase();
    const matches = places.filter(
      (place) =>
        place.name.toLowerCase().includes(needle) &&
        (primaryType === undefined || place.primaryType === primaryType),
    );
    if (matches.length === 0) {
      problems.push(`"${key}" (${nameFragment}) matched no recorded place`);
      continue;
    }
    // An exact name wins, so "de young museum" is the museum and not the
    // "de Young Museum Store" next to it. Otherwise the first match is used:
    // the recorded list is nearest-first, so "peet's" resolves to the Peet's
    // the user is standing at rather than one across the terminal.
    const exactMatch = matches.find((place) => place.name.toLowerCase() === needle);
    resolved[key] = (exactMatch ?? matches[0]).id;
  }
  if (problems.length > 0) {
    throw new Error(
      `Scenario ${definition.name}: ${problems.join("; ")}. Adjust placeKeys in ranking-scenarios.ts to match the recorded names: ${places
        .map((place) => place.name)
        .join(", ")}`,
    );
  }
  return resolved;
}

/** Offset in minutes of `timeZone` from UTC at `instant`. */
function timeZoneOffsetMinutes(instant: Date, timeZone: string): number {
  const parts = new Intl.DateTimeFormat("en-US", {
    timeZone,
    hourCycle: "h23",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
  }).formatToParts(instant);
  const value = (type: string) => Number(parts.find((part) => part.type === type)?.value);
  const asUtc = Date.UTC(
    value("year"),
    value("month") - 1,
    value("day"),
    value("hour"),
    value("minute"),
    value("second"),
  );
  return Math.round((asUtc - instant.getTime()) / 60_000);
}

/** The instant at which a wall-clock time occurs in `timeZone`. */
export function zonedDate(
  wallClock: { year: number; month: number; day: number; hour: number; minute: number },
  timeZone: string,
): Date {
  const naive = Date.UTC(
    wallClock.year,
    wallClock.month - 1,
    wallClock.day,
    wallClock.hour,
    wallClock.minute,
  );
  // Two passes handle the case where the first guess lands on the other side
  // of a daylight-saving transition.
  let guess = new Date(naive - timeZoneOffsetMinutes(new Date(naive), timeZone) * 60_000);
  guess = new Date(naive - timeZoneOffsetMinutes(guess, timeZone) * 60_000);
  return guess;
}

function localDayOfWeek(instant: Date, timeZone: string): number {
  const weekday = new Intl.DateTimeFormat("en-US", { timeZone, weekday: "short" }).format(instant);
  return ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"].indexOf(weekday);
}

function localCalendarDay(instant: Date, timeZone: string) {
  const parts = new Intl.DateTimeFormat("en-US", {
    timeZone,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).formatToParts(instant);
  const value = (type: string) => Number(parts.find((part) => part.type === type)?.value);
  return { year: value("year"), month: value("month"), day: value("day") };
}

const DAY_MILLISECONDS = 24 * 60 * 60 * 1000;

/**
 * Deterministic visit times: `visits` spread evenly over `spanDays`, nudged
 * onto the requested kind of day, at `hourOfDay` with a few minutes of jitter
 * so no two visits share a timestamp.
 */
export function synthesizeHistory(
  template: HistoryTemplate,
  place: PlaceResult,
  referenceNow: Date,
  timeZone: string,
): FixtureHistoryEntry[] {
  const entries: FixtureHistoryEntry[] = [];
  const daysBetweenVisits = template.spanDays / template.visits;
  for (let index = 0; index < template.visits; index += 1) {
    let dayInstant = new Date(
      referenceNow.getTime() - Math.round((index + 1) * daysBetweenVisits) * DAY_MILLISECONDS,
    );
    const wantedDays = template.days ?? "any";
    for (let attempt = 0; attempt < 7; attempt += 1) {
      const dayOfWeek = localDayOfWeek(dayInstant, timeZone);
      const isWeekend = dayOfWeek === 0 || dayOfWeek === 6;
      if (wantedDays === "any" || (wantedDays === "weekends") === isWeekend) {
        break;
      }
      dayInstant = new Date(dayInstant.getTime() - DAY_MILLISECONDS);
    }
    const calendarDay = localCalendarDay(dayInstant, timeZone);
    const createdAt = zonedDate(
      { ...calendarDay, hour: template.hourOfDay, minute: (index * 7) % 50 },
      timeZone,
    );
    entries.push({
      googlePlaceId: place.id,
      createdAt: createdAt.toISOString(),
      placeName: place.name,
      placeAddress: place.address,
      placePrimaryType: place.primaryType,
      placeTypes: place.types,
      location: place.location,
    });
  }
  return entries.sort((first, second) => first.createdAt.localeCompare(second.createdAt));
}

export function buildRankingFixture(
  definition: RankingScenarioDefinition,
  anchor: { latitude: number; longitude: number },
  google: RecordedGoogleData,
  recordedAt: string | null,
): RankingFixture {
  const resultLists: GooglePlace[][] = [];
  if (google.distance) {
    resultLists.push(google.distance.response.places ?? []);
  }
  resultLists.push(google.popularity.response.places ?? []);
  const places = mergeNearbyResults(resultLists).map(toResult);

  const placeKeys = resolvePlaceKeys(definition, places);
  const placesById = new Map(places.map((place) => [place.id, place]));
  const referenceNow = new Date(definition.referenceNow);

  const histories: Record<string, FixtureHistoryEntry[]> = {};
  for (const [historyKey, templates] of Object.entries(definition.histories)) {
    histories[historyKey] = templates
      .flatMap((template) => {
        const placeIdentifier = placeKeys[template.place];
        const place = placeIdentifier ? placesById.get(placeIdentifier) : undefined;
        if (!place) {
          throw new Error(
            `Scenario ${definition.name}: history "${historyKey}" refers to unknown place key "${template.place}"`,
          );
        }
        return synthesizeHistory(template, place, referenceNow, definition.timeZone);
      })
      .sort((first, second) => first.createdAt.localeCompare(second.createdAt));
  }

  for (const rankingCase of definition.cases) {
    if (!(rankingCase.history in histories)) {
      throw new Error(
        `Scenario ${definition.name}: case "${rankingCase.name}" refers to unknown history "${rankingCase.history}"`,
      );
    }
    const referencedKeys = [
      rankingCase.expect.top,
      rankingCase.expect.suggested,
      ...(rankingCase.expect.rankedAbove ?? []).flat(),
    ].filter((key): key is string => typeof key === "string");
    for (const key of referencedKeys) {
      if (!(key in placeKeys)) {
        throw new Error(
          `Scenario ${definition.name}: case "${rankingCase.name}" refers to unknown place key "${key}"`,
        );
      }
    }
  }

  return {
    schemaVersion: RANKING_FIXTURE_SCHEMA_VERSION,
    name: definition.name,
    description: definition.description,
    recordedAt,
    timeZone: definition.timeZone,
    fix: {
      ...offsetCoordinate(anchor, definition.offsetMeters),
      horizontalAccuracy: definition.horizontalAccuracy,
    },
    google,
    places,
    placeKeys,
    histories,
    cases: definition.cases.map((rankingCase) => ({
      name: rankingCase.name,
      now: rankingCase.now,
      horizontalAccuracy: rankingCase.horizontalAccuracy ?? definition.horizontalAccuracy,
      fixAgeSeconds: rankingCase.fixAgeSeconds ?? 5,
      history: rankingCase.history,
      expect: rankingCase.expect,
    })),
  };
}
