/**
 * Measures the checkin ranking against real checkins: for each imported
 * Swarm checkin whose venue is matched to an Overture place (see
 * `npm run overture:bridge`), stand a little way from that place's pin, ask
 * the database for candidates the way `GET /places` does, rank them with the
 * app's own PlaceRanker, and note where the true venue landed.
 *
 *   npm run ranking:evaluate                          # 300 checkins, the app's weights
 *   npm run ranking:evaluate -- --cases 1000
 *   npm run ranking:evaluate -- --pin-error 12 --prior-weight 0   # the old ranker
 *   npm run ranking:evaluate -- --point-radius 10
 *   npm run ranking:evaluate -- --show-misses
 *
 * The fixes are the pin plus Gaussian noise (35 m per axis, about what a
 * phone and a pin disagree by on a dense block), with the reported accuracy
 * cycling through 5, 30 and 65 m; the same seed every run, so two runs with
 * different weights see the same fixes. No history: this measures what the
 * ranker knows before it has learned anything about the user.
 *
 * One bias to keep in mind: the truths are found through Foursquare's
 * records in the bridge files, so nearly every one is corroborated by at
 * least Foursquare. The corroboration bonus therefore looks stronger here
 * than it is in general; sweep it with that discount.
 *
 * The ranker is compiled from the iOS sources with swiftc into api/build/,
 * so Xcode's command line tools are needed.
 */

import "../src/load-environment.js";
import { execFileSync, spawnSync } from "node:child_process";
import { existsSync, mkdirSync, statSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { and, asc, eq, isNotNull, isNull } from "drizzle-orm";
import { alias } from "drizzle-orm/pg-core";
import { database } from "../src/db/index.js";
import { checkins, foursquareVenues, places } from "../src/db/schema.js";
import { toPlaceResult, type PlaceResult } from "../src/lib/place-result.js";
import { searchNearbyCandidates } from "../src/lib/places-search.js";

const scriptsDirectory = path.dirname(fileURLToPath(import.meta.url));
const repositoryRoot = path.join(scriptsDirectory, "..", "..");
const buildDirectory = path.join(scriptsDirectory, "..", "build");
const rankerBinary = path.join(buildDirectory, "ranking-evaluate");

/** The iOS sources the ranker needs, all Foundation-only. */
const RANKER_SOURCES = [
  "ios/Hackysack/Place.swift",
  "ios/Hackysack/CheckinHistoryEntry.swift",
  "ios/Hackysack/PlaceFootprint.swift",
  "ios/Hackysack/PlaceRanker.swift",
].map((relative) => path.join(repositoryRoot, relative));

const DEFAULT_CASE_COUNT = 300;
const NOISE_METERS_PER_AXIS = 35;
const ACCURACIES = [5, 30, 65];
const SEARCH_RADIUS_METERS = 1500;

interface Options {
  caseCount: number;
  showMisses: boolean;
  weights: Record<string, number>;
}

function parseOptions(argv: string[]): Options {
  const options: Options = { caseCount: DEFAULT_CASE_COUNT, showMisses: false, weights: {} };
  const weightFlags: Record<string, string> = {
    "--spatial": "spatial",
    "--pin-error": "pinPlacementError",
    "--point-radius": "pointRadius",
    "--popularity-weight": "popularity",
    "--prior-weight": "prior",
  };
  for (let index = 0; index < argv.length; index += 1) {
    const flag = argv[index]!;
    if (flag === "--cases") {
      options.caseCount = Number(argv[++index]);
    } else if (flag === "--show-misses") {
      options.showMisses = true;
    } else if (flag in weightFlags) {
      options.weights[weightFlags[flag]!] = Number(argv[++index]);
    } else {
      throw new Error(`Unknown option ${flag}`);
    }
  }
  return options;
}

/** Rebuilds the ranker binary when any of its sources is newer than it. */
function compileRanker(): void {
  const mainSource = path.join(scriptsDirectory, "ranking-evaluate", "main.swift");
  const sources = [...RANKER_SOURCES, mainSource];
  if (existsSync(rankerBinary)) {
    const builtAt = statSync(rankerBinary).mtimeMs;
    if (sources.every((source) => statSync(source).mtimeMs < builtAt)) {
      return;
    }
  }
  mkdirSync(buildDirectory, { recursive: true });
  console.log("compiling the ranker from the iOS sources");
  execFileSync("xcrun", ["swiftc", "-O", "-swift-version", "6", "-o", rankerBinary, ...sources], { stdio: "inherit" });
}

/** A small deterministic generator (mulberry32), so every run sees the same fixes. */
function seededRandom(seed: number): () => number {
  let state = seed >>> 0;
  return () => {
    state = (state + 0x6d2b79f5) >>> 0;
    let mixed = Math.imul(state ^ (state >>> 15), 1 | state);
    mixed = (mixed + Math.imul(mixed ^ (mixed >>> 7), 61 | mixed)) ^ mixed;
    return ((mixed ^ (mixed >>> 14)) >>> 0) / 4294967296;
  };
}

function gaussian(random: () => number): number {
  const first = Math.max(random(), Number.EPSILON);
  const second = random();
  return Math.sqrt(-2 * Math.log(first)) * Math.cos(2 * Math.PI * second);
}

interface Truth {
  checkinId: string;
  placeId: string;
  name: string;
  latitude: number;
  longitude: number;
}

/** Imported checkins whose Foursquare venue is matched to a live Overture place with a pin. */
async function loadTruths(limit: number): Promise<Truth[]> {
  // The checkin points at the Foursquare copy of the venue; the Overture
  // copy, which the search returns, is reached through the bridge match.
  const foursquarePlace = alias(places, "foursquare_place");
  const rows = await database
    .select({
      checkinId: checkins.id,
      placeId: places.id,
      name: places.name,
      latitude: places.latitude,
      longitude: places.longitude,
    })
    .from(checkins)
    .innerJoin(foursquarePlace, eq(foursquarePlace.id, checkins.placeId))
    .innerJoin(foursquareVenues, eq(foursquareVenues.id, foursquarePlace.foursquareVenueId))
    .innerJoin(places, eq(places.overtureId, foursquareVenues.overtureId))
    .where(and(isNotNull(foursquareVenues.overtureId), isNull(places.retiredAt), eq(places.source, "overture")))
    .orderBy(asc(checkins.id))
    .limit(limit);
  return rows.filter((row): row is Truth => row.latitude !== null && row.longitude !== null);
}

interface EvaluationCase {
  name: string;
  truthId: string;
  fix: { latitude: number; longitude: number; horizontalAccuracy: number };
  candidates: PlaceResult[];
}

interface EvaluationResult {
  name: string;
  rank: number;
  candidateCount: number;
  suggested: boolean;
  leaders: string[];
}

async function buildCases(truths: Truth[]): Promise<EvaluationCase[]> {
  const random = seededRandom(20260925);
  const cases: EvaluationCase[] = [];
  for (const [index, truth] of truths.entries()) {
    const metersPerDegreeLatitude = 111_320;
    const metersPerDegreeLongitude = metersPerDegreeLatitude * Math.cos((truth.latitude * Math.PI) / 180);
    const fix = {
      latitude: truth.latitude + (gaussian(random) * NOISE_METERS_PER_AXIS) / metersPerDegreeLatitude,
      longitude: truth.longitude + (gaussian(random) * NOISE_METERS_PER_AXIS) / metersPerDegreeLongitude,
      horizontalAccuracy: ACCURACIES[index % ACCURACIES.length]!,
    };
    const candidates = await searchNearbyCandidates({
      latitude: fix.latitude,
      longitude: fix.longitude,
      radius: SEARCH_RADIUS_METERS,
      accuracy: fix.horizontalAccuracy,
      viewerUserId: null,
    });
    cases.push({ name: truth.name, truthId: truth.placeId, fix, candidates: candidates.map(toPlaceResult) });
    if ((index + 1) % 50 === 0) {
      console.log(`${index + 1} of ${truths.length} cases prepared`);
    }
  }
  return cases;
}

function rank(cases: EvaluationCase[], weights: Record<string, number>): EvaluationResult[] {
  const run = spawnSync(rankerBinary, [], {
    input: JSON.stringify({ cases, weights, now: new Date().toISOString() }),
    encoding: "utf-8",
    maxBuffer: 256 * 1024 * 1024,
  });
  if (run.status !== 0) {
    throw new Error(`The ranker failed: ${run.stderr}`);
  }
  return (JSON.parse(run.stdout) as { results: EvaluationResult[] }).results;
}

function percent(numerator: number, denominator: number): string {
  return denominator === 0 ? "-" : `${((100 * numerator) / denominator).toFixed(1)}%`;
}

function report(cases: EvaluationCase[], results: EvaluationResult[], showMisses: boolean): void {
  const groups = new Map<string, { cases: EvaluationCase[]; results: EvaluationResult[] }>();
  for (const [index, evaluationCase] of cases.entries()) {
    const key = `${evaluationCase.fix.horizontalAccuracy} m`;
    const group = groups.get(key) ?? { cases: [], results: [] };
    group.cases.push(evaluationCase);
    group.results.push(results[index]!);
    groups.set(key, group);
  }
  groups.set("all", { cases, results });

  console.log("");
  console.log("accuracy   cases   top-1    top-3    MRR     suggested  missing");
  for (const [label, group] of groups) {
    const total = group.results.length;
    const top1 = group.results.filter((result) => result.rank === 1).length;
    const top3 = group.results.filter((result) => result.rank >= 1 && result.rank <= 3).length;
    const suggested = group.results.filter((result) => result.suggested).length;
    const missing = group.results.filter((result) => result.rank === 0).length;
    const reciprocal = group.results.reduce((sum, result) => sum + (result.rank > 0 ? 1 / result.rank : 0), 0);
    console.log(
      `${label.padEnd(10)} ${String(total).padStart(5)}   ${percent(top1, total).padEnd(8)} ${percent(top3, total).padEnd(8)} ` +
        `${(total ? reciprocal / total : 0).toFixed(3)}   ${percent(suggested, total).padEnd(10)} ${percent(missing, total)}`,
    );
  }

  if (showMisses) {
    console.log("");
    for (const [index, result] of results.entries()) {
      if (result.rank === 1) {
        continue;
      }
      const evaluationCase = cases[index]!;
      console.log(
        `#${result.rank || "-"} ${evaluationCase.name} (${evaluationCase.fix.horizontalAccuracy} m): ${result.leaders.join(", ")}`,
      );
    }
  }
}

async function main(): Promise<void> {
  const options = parseOptions(process.argv.slice(2));
  compileRanker();
  const truths = await loadTruths(options.caseCount);
  if (truths.length === 0) {
    throw new Error("No imported checkins are matched to Overture places yet; run `npm run overture:bridge` first.");
  }
  console.log(`${truths.length} checkins at matched venues`);
  const cases = await buildCases(truths);
  const results = rank(cases, options.weights);
  if (Object.keys(options.weights).length > 0) {
    console.log(`weights: ${JSON.stringify(options.weights)}`);
  }
  report(cases, results, options.showMisses);
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
