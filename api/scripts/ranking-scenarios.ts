/**
 * Definitions for the checkin-ranking fixtures in `fixtures/ranking/`.
 *
 * Each scenario is a real spot the user might be standing in, given as the
 * coordinate of the fix and a GPS accuracy. Places the tests need to refer to
 * are given short keys resolved by name against the recorded results, so
 * re-recording never breaks a test because an id changed. Histories are
 * synthesized from templates relative to a fixed reference time, never
 * `Date.now()`, so recordings are reproducible.
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
  /** Where the user stands. */
  fix: { latitude: number; longitude: number };
  horizontalAccuracy: number;
  /** Nearby search radius; defaults to the API's default. */
  radius?: number;
  /**
   * Case-insensitive substrings matched against recorded names. The object
   * form also requires a primary type, for when the data holds a record with
   * the same name as the venue (an airport's terminal, a museum's store).
   */
  placeKeys: Record<string, string | { name: string; primaryType: string }>;
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
      "Standing outside the council chambers at Truckee Town Hall. The data lists a dozen town departments (police, engineering, planning...) within 25 m of it; every popular place is hundreds of meters away.",
    timeZone: PACIFIC,
    fix: { latitude: 39.316962, longitude: -120.146008 },
    horizontalAccuracy: 30,
    placeKeys: {
      townHall: "truckee town hall & town clerk",
      police: "truckee police department",
      sportsPark: "riverview sports park",
      airport: "truckee tahoe airport",
    },
    referenceNow: "2026-09-22T10:15:00-07:00",
    histories: {
      none: [],
      councilRegular: [{ place: "townHall", visits: 6, hourOfDay: 10, spanDays: 90, days: "weekdays" }],
    },
    cases: [
      {
        // The town hall leads its own departments, but with a dozen listings
        // in the building and no history that is not enough to skip the list.
        name: "accurate fix, no history",
        now: "2026-09-22T10:15:00-07:00",
        history: "none",
        expect: {
          top: "townHall",
          suggested: null,
          rankedAbove: [
            ["townHall", "police"],
            ["townHall", "airport"],
            ["townHall", "sportsPark"],
          ],
        },
      },
      {
        name: "accurate fix, council regular",
        now: "2026-09-22T10:15:00-07:00",
        history: "councilRegular",
        expect: { top: "townHall", suggested: "townHall" },
      },
      {
        // At 300 m nothing is certain; the only requirement is no auto-jump
        // and that an obscure venue still beats a popular park 1.6 km away.
        name: "coarse fix, no history",
        now: "2026-09-22T10:15:00-07:00",
        horizontalAccuracy: 300,
        history: "none",
        expect: { suggested: null, rankedAbove: [["townHall", "sportsPark"]] },
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
    name: "truckee-lift-workspace",
    description:
      "Inside Lift Workspace, a coworking space by the Truckee airport. Its building and the lot next door hold a physical therapist, a realty office, three car rental counters and half a dozen registered businesses within 40 m.",
    timeZone: PACIFIC,
    fix: { latitude: 39.318649, longitude: -120.146375 },
    horizontalAccuracy: 12,
    placeKeys: {
      lift: "lift workspace",
      enterprise: "enterprise rent-a-car",
      nationalCarRental: "national car rental",
      synergy: "synergy healing arts",
    },
    referenceNow: "2026-09-23T14:00:00-07:00",
    histories: {
      none: [],
      coworkingRegular: [{ place: "lift", visits: 8, hourOfDay: 10, spanDays: 60, days: "weekdays" }],
    },
    cases: [
      {
        // A tight fix in a building full of unrelated businesses: several
        // plausible answers, so the list must be shown.
        name: "tight fix, no history",
        now: "2026-09-23T14:00:00-07:00",
        history: "none",
        // Lift and the rental counters share a pin and, with no checkins
        // yet, a score; only history can separate them.
        expect: { suggested: null },
      },
      {
        name: "tight fix, coworking regular",
        now: "2026-09-23T10:20:00-07:00",
        history: "coworkingRegular",
        expect: { top: "lift", suggested: "lift" },
      },
    ],
  },
  {
    name: "jfk-terminal-8",
    description:
      "At a bar in JFK Terminal 8, 1.4 km from the airport's pin. The twenty nearest places from here are rental counters and hotels but never the airport; the large-venue search finds it.",
    timeZone: "America/New_York",
    fix: { latitude: 40.649158, longitude: -73.795435 },
    horizontalAccuracy: 40,
    placeKeys: {
      airport: { name: "john f. kennedy international airport", primaryType: "airport" },
      bar: "dos toros",
    },
    referenceNow: "2026-09-22T17:30:00-04:00",
    histories: {
      none: [],
    },
    cases: [
      {
        name: "terminal fix, no history",
        now: "2026-09-22T17:30:00-04:00",
        history: "none",
        // Overture places are points, so the airport's 1.5 km footprint is
        // a guess the ranker cannot confirm: the bar the user is standing
        // in leads, the airport follows, and the list is shown. A recorded
        // extent (see PlaceFootprint) would make the airport the answer.
        expect: { suggested: null },
      },
    ],
  },
  {
    name: "sfo-terminal-2",
    description:
      "In line at Peet's inside SFO Terminal 2, about a kilometer from the airport's pin but well inside its recorded grounds.",
    timeZone: PACIFIC,
    fix: { latitude: 37.6171541, longitude: -122.3814167 },
    horizontalAccuracy: 65,
    placeKeys: {
      airport: { name: "san francisco international airport", primaryType: "airport" },
      peets: "peet's coffee",
      larkCreek: "lark creek grill",
    },
    referenceNow: "2026-09-22T07:30:00-07:00",
    histories: {
      none: [],
      peetsRegular: [{ place: "peets", visits: 5, hourOfDay: 7, spanDays: 60, days: "weekdays" }],
    },
    cases: [
      {
        // A 65 m fix cannot resolve which Terminal 2 storefront you are in,
        // but the airport's recorded grounds say you are inside it, and an
        // airport is the checkin when you are in one: it is suggested outright.
        name: "terminal fix, no history",
        now: "2026-09-22T07:30:00-07:00",
        history: "none",
        expect: {
          top: "airport",
          suggested: "airport",
          rankedAbove: [
            ["airport", "larkCreek"],
            ["airport", "peets"],
          ],
        },
      },
      {
        // Even a tight fix at the counter of a storefront nobody has checked
        // in at is, first of all, a fix inside the airport.
        name: "tight fix, no history",
        now: "2026-09-22T07:30:00-07:00",
        horizontalAccuracy: 8,
        history: "none",
        expect: { top: "airport", suggested: "airport", rankedAbove: [["peets", "larkCreek"]] },
      },
      {
        // A regular's own history outweighs the airport around them, and the
        // airport, which encloses Peet's, is not an alternative to it, so
        // Peet's is still confident enough to be suggested.
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
    fix: { latitude: 37.404035, longitude: -121.970056 },
    horizontalAccuracy: 45,
    placeKeys: {
      stadium: "levi's stadium",
      museum: "49ers museum",
      greatAmerica: "great america",
      university: "mission college",
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
        // Top, but the museum at the gate keeps it from being suggested
        // outright: the stadium's extent is a table guess, not recorded.
        expect: {
          top: "stadium",
          suggested: null,
          rankedAbove: [
            ["stadium", "museum"],
            ["stadium", "greatAmerica"],
            ["stadium", "university"],
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
    fix: { latitude: 37.771334, longitude: -122.468539 },
    horizontalAccuracy: 30,
    placeKeys: {
      deYoung: "de young museum",
      park: { name: "golden gate park", primaryType: "park" },
      museumStore: "de young museum store",
      kezarStadium: "kezar stadium",
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
        // Golden Gate Park's pin is 1.3 km from the de Young. With no
        // recorded extent the park is scored as a 150 m neighborhood park
        // that far away, so nothing is expected of its position.
        expect: {
          top: "deYoung",
          suggested: null,
          rankedAbove: [["deYoung", "museumStore"]],
        },
      },
      {
        // The runner's history is at the park, but its pin is 1.3 km away
        // and the ranker has no extent to place the user inside it: history
        // never outweighs geometry, so the museum entrance still leads and
        // nothing is suggested. Re-record once places carry an extent.
        name: "morning park runner",
        now: "2026-09-19T07:10:00-07:00",
        history: "parkRunner",
        expect: { top: "deYoung", suggested: null },
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
    name: "soma-second-street",
    description:
      "Outside Blue Bottle on 2nd Street in SoMa. The building shares its pin with a consulate and a dozen registered-office startups; Yerba Buena Gardens and Salesforce Park are 400 m away and Oracle Park 1.2 km.",
    timeZone: PACIFIC,
    fix: { latitude: 37.78697, longitude: -122.398863 },
    horizontalAccuracy: 12,
    placeKeys: {
      blueBottle: "blue bottle",
      gym: "social fit club",
      ballpark: "oracle park",
    },
    referenceNow: "2026-09-22T08:30:00-07:00",
    histories: {
      none: [],
      coffeeRegular: [{ place: "blueBottle", visits: 30, hourOfDay: 8, spanDays: 90, days: "weekdays" }],
      neighborhoodRegular: [
        { place: "blueBottle", visits: 12, hourOfDay: 8, spanDays: 90, days: "weekdays" },
        { place: "gym", visits: 10, hourOfDay: 20, spanDays: 90, days: "any" },
      ],
    },
    cases: [
      {
        name: "tight fix, no history",
        now: "2026-09-22T08:30:00-07:00",
        history: "none",
        expect: { top: "blueBottle", suggested: null, rankedAbove: [["blueBottle", "ballpark"]] },
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
        expect: { top: "blueBottle", rankedAbove: [["blueBottle", "gym"]] },
      },
      {
        name: "evening, regular at both",
        now: "2026-09-25T20:30:00-07:00",
        history: "neighborhoodRegular",
        expect: { top: "gym", rankedAbove: [["gym", "blueBottle"]] },
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
    name: "downtown-redwood-city",
    description:
      "Outside Peet's on Broadway in downtown Redwood City, among restaurants and salons, 170 m from the Caltrain station and 650 m from Mezes Park.",
    timeZone: PACIFIC,
    fix: { latitude: 37.486525, longitude: -122.233389 },
    horizontalAccuracy: 20,
    placeKeys: {
      peets: "peet's",
      kemuri: "kemuri japanese",
      park: "mezes park",
      caltrain: "redwood city",
    },
    referenceNow: "2026-09-19T09:00:00-07:00",
    histories: {
      none: [],
      parkRegular: [{ place: "park", visits: 10, hourOfDay: 18, spanDays: 60, days: "any" }],
      dinnerRegular: [{ place: "kemuri", visits: 8, hourOfDay: 19, spanDays: 90, days: "any" }],
    },
    cases: [
      {
        name: "no history",
        now: "2026-09-19T09:00:00-07:00",
        history: "none",
        expect: {
          suggested: null,
          rankedAbove: [
            ["peets", "park"],
            ["peets", "caltrain"],
          ],
        },
      },
      {
        // History never outweighs geometry: the park is 650 m away and the
        // fix is good to 20 m, so the user is not there tonight.
        name: "park regular in the evening",
        now: "2026-09-19T18:15:00-07:00",
        history: "parkRegular",
        expect: { suggested: null, rankedAbove: [["peets", "park"]] },
      },
      {
        name: "dinner regular in the evening",
        now: "2026-09-19T19:10:00-07:00",
        history: "dinnerRegular",
        expect: { top: "kemuri", rankedAbove: [["kemuri", "peets"]] },
      },
    ],
  },
];
