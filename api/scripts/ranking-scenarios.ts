/**
 * Definitions for the checkin-ranking fixtures in `fixtures/ranking/`.
 *
 * Each scenario is a real place the user might be standing in, described by a
 * text query that the recorder resolves against Google (so nobody has to hand
 * copy coordinates or place IDs), an offset from that anchor, and a GPS
 * accuracy. Places the tests need to refer to are given short keys resolved by
 * name against the recorded results, so re-recording never breaks a test
 * because an ID changed. Histories are synthesized from templates relative to
 * a fixed reference time, never `Date.now()`, so recordings are reproducible.
 */

export interface HistoryTemplate {
  /** Key of the place (from `placeKeys`) the visits are at. */
  place: string;
  visits: number;
  /** Local hour of day the visits cluster around. */
  hourOfDay: number;
  /** Visits spread evenly over this many days back from `referenceNow`. */
  spanDays: number;
  days?: "weekdays" | "weekends" | "any";
}

export interface RankingCaseExpectation {
  /** Key of the place expected to rank first. */
  top?: string;
  /** Key of the place expected to be auto-suggested, or null for "no suggestion". */
  suggested?: string | null;
  /** Pairs of keys [above, below] that must rank in that order. */
  rankedAbove?: [string, string][];
}

export interface RankingCaseDefinition {
  name: string;
  /** ISO 8601 with offset. Both decay and hour-of-day are computed from this. */
  now: string;
  /** Overrides the scenario's accuracy for this case. */
  horizontalAccuracy?: number;
  /** How old the fix is at `now`. Defaults to 5 seconds. */
  fixAgeSeconds?: number;
  /** Key into the scenario's histories. */
  history: string;
  expect: RankingCaseExpectation;
}

export interface RankingScenarioDefinition {
  name: string;
  description: string;
  timeZone: string;
  /** Text query resolved with Places Text Search to find the anchor place. */
  anchorQuery: string;
  /** Where the user stands relative to the anchor's pin, in meters. */
  offsetMeters: { north: number; east: number };
  horizontalAccuracy: number;
  /** Nearby Search radius; defaults to the API's default. */
  radius?: number;
  /** Case-insensitive substrings matched against recorded display names. */
  placeKeys: Record<string, string>;
  /** Histories are generated relative to this instant. */
  referenceNow: string;
  histories: Record<string, HistoryTemplate[]>;
  cases: RankingCaseDefinition[];
}

const PACIFIC = "America/Los_Angeles";

export const rankingScenarios: RankingScenarioDefinition[] = [
  {
    name: "truckee-town-hall",
    description:
      "Standing outside the council chambers at Truckee Town Hall. It is the only venue inside the accuracy circle; every popular place is hundreds of meters away.",
    timeZone: PACIFIC,
    anchorQuery: "Truckee Town Hall, Truckee, CA",
    offsetMeters: { north: 12, east: 15 },
    horizontalAccuracy: 30,
    placeKeys: {
      townHall: "town hall",
      regionalPark: "truckee river regional park",
      brewery: "fiftyfifty",
      airport: "truckee tahoe airport",
    },
    referenceNow: "2026-09-22T10:15:00-07:00",
    histories: {
      none: [],
      councilRegular: [{ place: "townHall", visits: 6, hourOfDay: 10, spanDays: 90, days: "weekdays" }],
    },
    cases: [
      {
        name: "accurate fix, no history",
        now: "2026-09-22T10:15:00-07:00",
        history: "none",
        expect: {
          top: "townHall",
          suggested: "townHall",
          rankedAbove: [
            ["townHall", "regionalPark"],
            ["townHall", "brewery"],
          ],
        },
      },
      {
        // At 300 m nothing is certain; the only requirement is no auto-jump
        // and that an obscure venue still beats a popular one 1.3 km away.
        name: "coarse fix, no history",
        now: "2026-09-22T10:15:00-07:00",
        horizontalAccuracy: 300,
        history: "none",
        expect: { suggested: null, rankedAbove: [["townHall", "brewery"]] },
      },
      {
        name: "coarse fix, council regular",
        now: "2026-09-22T10:15:00-07:00",
        horizontalAccuracy: 300,
        history: "councilRegular",
        expect: { top: "townHall", suggested: null },
      },
      {
        name: "stale fix, no history",
        now: "2026-09-22T10:15:00-07:00",
        fixAgeSeconds: 120,
        history: "none",
        expect: { top: "townHall", suggested: null },
      },
    ],
  },
  {
    name: "sfo-terminal-2",
    description:
      "In line at Peet's inside SFO Terminal 2, about 900 m from the airport's pin but well inside its viewport.",
    timeZone: PACIFIC,
    anchorQuery: "Peet's Coffee, Terminal 2, San Francisco International Airport",
    offsetMeters: { north: 6, east: 8 },
    horizontalAccuracy: 65,
    placeKeys: {
      airport: "san francisco international airport",
      peets: "peet's",
      napaFarms: "napa farms",
    },
    referenceNow: "2026-09-22T07:30:00-07:00",
    histories: {
      none: [],
      peetsRegular: [{ place: "peets", visits: 5, hourOfDay: 7, spanDays: 60, days: "weekdays" }],
    },
    cases: [
      {
        // A 65 m fix cannot resolve which Terminal 2 storefront you are in,
        // so the airport (or its terminal) should outrank every one of them.
        name: "terminal fix, no history",
        now: "2026-09-22T07:30:00-07:00",
        history: "none",
        expect: {
          suggested: null,
          rankedAbove: [
            ["airport", "napaFarms"],
            ["airport", "peets"],
          ],
        },
      },
      {
        name: "tight fix, no history",
        now: "2026-09-22T07:30:00-07:00",
        horizontalAccuracy: 8,
        history: "none",
        expect: { suggested: null, rankedAbove: [["peets", "napaFarms"]] },
      },
      {
        name: "tight fix, morning coffee regular",
        now: "2026-09-22T07:30:00-07:00",
        horizontalAccuracy: 8,
        history: "peetsRegular",
        expect: { top: "peets", suggested: "peets", rankedAbove: [["peets", "airport"]] },
      },
    ],
  },
  {
    name: "levis-stadium",
    description:
      "On the concourse inside Levi's Stadium on a Sunday afternoon, 100 m from the pin.",
    timeZone: PACIFIC,
    anchorQuery: "Levi's Stadium, Santa Clara, CA",
    offsetMeters: { north: 80, east: -60 },
    horizontalAccuracy: 45,
    placeKeys: {
      stadium: "levi's stadium",
      museum: "49ers museum",
      greatAmerica: "great america",
      conventionCenter: "santa clara convention center",
    },
    referenceNow: "2026-09-20T13:05:00-07:00",
    histories: {
      none: [],
      seasonTicketHolder: [{ place: "stadium", visits: 4, hourOfDay: 13, spanDays: 120, days: "weekends" }],
    },
    cases: [
      {
        name: "game day, no history",
        now: "2026-09-20T13:05:00-07:00",
        history: "none",
        expect: {
          top: "stadium",
          suggested: null,
          rankedAbove: [
            ["stadium", "greatAmerica"],
            ["stadium", "conventionCenter"],
          ],
        },
      },
      {
        name: "game day, season ticket holder",
        now: "2026-09-20T13:05:00-07:00",
        history: "seasonTicketHolder",
        expect: { top: "stadium", suggested: "stadium" },
      },
    ],
  },
  {
    name: "golden-gate-park-de-young",
    description:
      "At the entrance of the de Young Museum, inside Golden Gate Park, with the Academy of Sciences across the concourse.",
    timeZone: PACIFIC,
    anchorQuery: "de Young Museum, San Francisco",
    offsetMeters: { north: -15, east: 12 },
    horizontalAccuracy: 30,
    placeKeys: {
      deYoung: "de young",
      park: "golden gate park",
      academy: "academy of sciences",
      teaGarden: "japanese tea garden",
    },
    referenceNow: "2026-09-19T11:00:00-07:00",
    histories: {
      none: [],
      parkRunner: [{ place: "park", visits: 20, hourOfDay: 7, spanDays: 90, days: "any" }],
      museumMember: [{ place: "deYoung", visits: 8, hourOfDay: 11, spanDays: 180, days: "any" }],
    },
    cases: [
      {
        name: "no history",
        now: "2026-09-19T11:00:00-07:00",
        history: "none",
        expect: {
          top: "deYoung",
          suggested: null,
          rankedAbove: [
            ["deYoung", "academy"],
            ["park", "teaGarden"],
          ],
        },
      },
      {
        name: "morning park runner",
        now: "2026-09-19T07:10:00-07:00",
        history: "parkRunner",
        expect: { top: "park", suggested: "park" },
      },
      {
        name: "museum member",
        now: "2026-09-19T11:00:00-07:00",
        history: "museumMember",
        expect: { top: "deYoung", suggested: "deYoung" },
      },
    ],
  },
  {
    name: "soma-mint-plaza",
    description:
      "On Mint Plaza in SoMa, between Blue Bottle and 54 Mint, with a shopping mall, a BART station and a landmark within two blocks.",
    timeZone: PACIFIC,
    anchorQuery: "Blue Bottle Coffee, 66 Mint St, San Francisco",
    offsetMeters: { north: -4, east: 3 },
    horizontalAccuracy: 12,
    placeKeys: {
      blueBottle: "blue bottle",
      fiftyFourMint: "54 mint",
      mintPlaza: "mint plaza",
      oldMint: "old mint",
      mall: "san francisco centre",
      bart: "powell",
    },
    referenceNow: "2026-09-22T08:30:00-07:00",
    histories: {
      none: [],
      coffeeRegular: [{ place: "blueBottle", visits: 30, hourOfDay: 8, spanDays: 90, days: "weekdays" }],
      neighborhoodRegular: [
        { place: "blueBottle", visits: 12, hourOfDay: 8, spanDays: 90, days: "weekdays" },
        { place: "fiftyFourMint", visits: 10, hourOfDay: 20, spanDays: 90, days: "any" },
      ],
    },
    cases: [
      {
        name: "tight fix, no history",
        now: "2026-09-22T08:30:00-07:00",
        history: "none",
        expect: { top: "blueBottle", suggested: null, rankedAbove: [["blueBottle", "mall"]] },
      },
      {
        name: "tight fix, coffee regular",
        now: "2026-09-22T08:30:00-07:00",
        history: "coffeeRegular",
        expect: { top: "blueBottle", suggested: "blueBottle" },
      },
      {
        name: "morning, regular at both",
        now: "2026-09-22T08:30:00-07:00",
        history: "neighborhoodRegular",
        expect: { top: "blueBottle", rankedAbove: [["blueBottle", "fiftyFourMint"]] },
      },
      {
        name: "evening, regular at both",
        now: "2026-09-25T20:30:00-07:00",
        history: "neighborhoodRegular",
        expect: { top: "fiftyFourMint", rankedAbove: [["fiftyFourMint", "blueBottle"]] },
      },
      {
        name: "coarse fix, no history",
        now: "2026-09-22T08:30:00-07:00",
        horizontalAccuracy: 300,
        history: "none",
        expect: { suggested: null },
      },
    ],
  },
  {
    name: "sequoia-station-strip-mall",
    description:
      "Outside Peet's at Sequoia Station, a Safeway-anchored strip mall in Redwood City next to the Caltrain station.",
    timeZone: PACIFIC,
    anchorQuery: "Peet's Coffee, Sequoia Station, Redwood City, CA",
    offsetMeters: { north: 10, east: -7 },
    horizontalAccuracy: 20,
    placeKeys: {
      peets: "peet's",
      safeway: "safeway",
      mall: "sequoia station",
      caltrain: "redwood city",
    },
    referenceNow: "2026-09-19T09:00:00-07:00",
    histories: {
      none: [],
      groceryRegular: [{ place: "safeway", visits: 10, hourOfDay: 18, spanDays: 60, days: "any" }],
    },
    cases: [
      {
        name: "no history",
        now: "2026-09-19T09:00:00-07:00",
        history: "none",
        expect: {
          suggested: null,
          rankedAbove: [
            ["peets", "safeway"],
            ["peets", "caltrain"],
          ],
        },
      },
      {
        name: "grocery regular in the evening",
        now: "2026-09-19T18:15:00-07:00",
        history: "groceryRegular",
        expect: { top: "safeway", rankedAbove: [["safeway", "peets"]] },
      },
    ],
  },
];
