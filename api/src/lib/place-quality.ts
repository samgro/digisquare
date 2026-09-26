/**
 * How likely a place is to be somewhere anyone would check in, before
 * distance and the user's own history are considered: a log-odds prior in
 * natural-log units, stored on every Overture row at import and added to
 * the app's ranking score. About 1.1 between two places means one is three
 * times as likely as the other, the same scale `PlaceRanker` uses.
 *
 * Two parts. A quality term asks whether the record is a real, open,
 * public-facing venue at all, from signals Overture carries but never turns
 * into a score. A category term says how often people check in at that kind
 * of place: restaurants and parks up, mortgage lenders and law firms down.
 *
 * What the signals are worth was measured on San Francisco in release
 * 2026-09-23.0 (73,584 places):
 *
 * - Every place has exactly one provider record; Overture promotes one
 *   source rather than merging them. BrightQuery, a feed built from business
 *   filings, is 41% of the city and supplies nearly every person-name and
 *   shell-company record (93% of `health_care`, 92% of `legal_service`).
 * - `confidence` is a fixed per-provider default (0.55, 0.77, 0.92, 0.95...)
 *   for every provider but Meta, whose scores are continuous. Overture says
 *   itself that the values are not comparable across providers. A low Meta
 *   score almost always comes with an unconfirmed `operating_status`.
 * - About 5% of places have no taxonomy or only its root (`health_care`,
 *   nothing more); nearly all of them are registry junk.
 * - The bridge files list every provider that matched a venue. 28% of
 *   places are matched by two or more, half of restaurants and bars, a tenth
 *   of professional services. That count is written by `overture-bridge.ts`
 *   after the import, so the bonus for it is added when a row is read
 *   (see `places-search.ts`) rather than folded into the stored prior.
 * - Microsoft and Foursquare records carry a real last-verified date; some
 *   Microsoft ones date from 2008. Every other provider's date is when the
 *   feed was delivered.
 */

/** Everything the prior is computed from, as the `places` row stores it. */
export interface PlaceQualitySignals {
  /** The provider the record came from, as `sources[].dataset` spells it. */
  sourceDataset: string | null;
  confidence: number | null;
  /** `open`, `temporarily_closed`, or null when no provider confirmed it. */
  operatingStatus: string | null;
  /** Overture's taxonomy path, root first: `["food_and_drink", "restaurant", ...]`. */
  taxonomyHierarchy: string[];
  /** The provider record's `update_time`. */
  sourceUpdatedAt: Date | null;
}

/** A record from a business-registry feed, with nobody else vouching for it. */
export const REGISTRY_FEED_PENALTY = -2;
/** A record with no category, or only a root one: not a venue anyone described. */
export const UNCATEGORIZED_PENALTY = -3;
/** A Microsoft or Foursquare record last verified before `STALE_SOURCE_BEFORE`. */
export const STALE_SOURCE_PENALTY = -1;
export const STALE_SOURCE_BEFORE = new Date("2023-01-01T00:00:00Z");
/** The most an unconfirmed record can lose for a low confidence. */
export const MINIMUM_CONFIDENCE_PRIOR = -3;

/** Per provider beyond the first that matched the same venue, up to the cap. */
export const CORROBORATION_BONUS_PER_PROVIDER = 0.5;
export const MAXIMUM_CORROBORATING_PROVIDERS = 2;

/**
 * Nearby searches leave out places whose prior is below this. A registry
 * record with no category lands here; a merely dull one does not. Name
 * searches ignore it, so anything can still be found by typing.
 */
export const HIDDEN_PRIOR_THRESHOLD = -4;

export const CATEGORY_BOOST = 1;
export const CATEGORY_PENALTY = -1.5;

const REGISTRY_FEEDS = new Set(["brightquery"]);
const DATED_PROVIDERS = new Set(["microsoft", "foursquare"]);

/**
 * Keyed by a taxonomy path prefix, joined with " > " as Overture's own CSV
 * writes them. A place takes the value of the longest prefix of its
 * hierarchy that is listed, so a root sets the default for everything under
 * it and a deeper entry carves out an exception. Anything unlisted is 0.
 */
const CATEGORY_PRIORS: Record<string, number> = {
  food_and_drink: CATEGORY_BOOST,

  lodging: CATEGORY_BOOST,
  // Apartments and vacation rentals: somebody's home, not a venue.
  "lodging > private_lodging": 0,

  arts_and_entertainment: CATEGORY_BOOST,
  "arts_and_entertainment > arts_and_crafts_space": 0,
  "arts_and_entertainment > ticket_office_or_booth": 0,
  "arts_and_entertainment > spiritual_advising": CATEGORY_PENALTY,

  sports_and_recreation: CATEGORY_BOOST,
  "sports_and_recreation > recreational_equipment_rental": 0,
  // A team or league is an organization, listed at an office.
  "sports_and_recreation > sport_league": CATEGORY_PENALTY,
  "sports_and_recreation > sport_team": CATEGORY_PENALTY,

  // Airports, stations, ferry terminals: canonical checkins.
  "travel_and_transportation > air_transport_facility_or_service": CATEGORY_BOOST,
  "travel_and_transportation > air_transport_facility_or_service > avionics_shop": CATEGORY_PENALTY,
  "travel_and_transportation > transport_interchange": CATEGORY_BOOST,
  "travel_and_transportation > ground_transport_facility_or_service": CATEGORY_BOOST,
  "travel_and_transportation > water_transport_facility_or_service": CATEGORY_BOOST,
  // Services listed under transport, with a dispatch office for a pin.
  "travel_and_transportation > ground_transport_facility_or_service > bus_ticket_agency": CATEGORY_PENALTY,
  "travel_and_transportation > ground_transport_facility_or_service > railway_ticket_agent": CATEGORY_PENALTY,
  "travel_and_transportation > ground_transport_facility_or_service > car_sharing": CATEGORY_PENALTY,
  "travel_and_transportation > ground_transport_facility_or_service > coach_bus": CATEGORY_PENALTY,
  "travel_and_transportation > ground_transport_facility_or_service > limo_service": CATEGORY_PENALTY,
  "travel_and_transportation > ground_transport_facility_or_service > pedicab_service": CATEGORY_PENALTY,
  "travel_and_transportation > ground_transport_facility_or_service > ride_share_service": CATEGORY_PENALTY,
  "travel_and_transportation > ground_transport_facility_or_service > taxi_service": CATEGORY_PENALTY,
  "travel_and_transportation > ground_transport_facility_or_service > town_car_service": CATEGORY_PENALTY,
  "travel_and_transportation > travel_service": CATEGORY_PENALTY,
  "travel_and_transportation > vehicle_service": CATEGORY_PENALTY,

  "shopping > shopping_mall": CATEGORY_BOOST,
  "shopping > market": CATEGORY_BOOST,
  "shopping > department_store": CATEGORY_BOOST,
  "shopping > superstore": CATEGORY_BOOST,
  "shopping > warehouse_club_store": CATEGORY_BOOST,
  "shopping > food_and_beverage_store": CATEGORY_BOOST,
  "shopping > shopping_service": CATEGORY_PENALTY,

  // Landmarks, memorials and cultural centers; churches stay neutral.
  cultural_and_historic: CATEGORY_BOOST,
  "cultural_and_historic > place_of_worship": 0,
  "cultural_and_historic > religious_retreat_or_center": 0,
  "cultural_and_historic > religious_organization": CATEGORY_PENALTY,

  "education > library": CATEGORY_BOOST,
  "education > place_of_learning > college_university": CATEGORY_BOOST,
  "education > educational_service": CATEGORY_PENALTY,
  "education > education_office": CATEGORY_PENALTY,
  "education > research_institute": CATEGORY_PENALTY,

  // The building is the checkin; the departments listed inside it are not.
  "community_and_government > government_office > town_hall": CATEGORY_BOOST,
  "community_and_government > government_office > courthouse": CATEGORY_BOOST,
  "community_and_government > civic_organization": CATEGORY_PENALTY,
  "community_and_government > social_or_community_service": CATEGORY_PENALTY,
  "community_and_government > military_site": CATEGORY_PENALTY,
  "community_and_government > public_utility": CATEGORY_PENALTY,

  // Beaches, peaks, viewpoints and gardens.
  geographic_entities: CATEGORY_BOOST,
  "geographic_entities > built_feature": 0,
  "geographic_entities > built_feature > botanical_garden": CATEGORY_BOOST,
  "geographic_entities > built_feature > community_garden": CATEGORY_BOOST,

  // Practitioners and clinics; a hospital or urgent care is a place you go.
  health_care: CATEGORY_PENALTY,
  "health_care > hospital": 0,
  "health_care > emergency_or_urgent_care_facility": 0,

  // Caterers. Salons, spas and pet groomers stay neutral.
  "lifestyle_services > food_service": CATEGORY_PENALTY,

  services_and_business: CATEGORY_PENALTY,
  "services_and_business > financial_service > bank_or_credit_union": 0,
  "services_and_business > laundry_service": 0,
  "services_and_business > rental_service": 0,
};

/** The listed value for the longest listed prefix of the hierarchy, else 0. */
export function categoryPrior(taxonomyHierarchy: readonly string[]): number {
  for (let depth = taxonomyHierarchy.length; depth > 0; depth -= 1) {
    const prior = CATEGORY_PRIORS[taxonomyHierarchy.slice(0, depth).join(" > ")];
    if (prior !== undefined) {
      return prior;
    }
  }
  return 0;
}

function logit(probability: number): number {
  return Math.log(probability / (1 - probability));
}

/**
 * What an unconfirmed record loses for a low confidence: the log-odds of
 * the score, floored, and never a gain. A confirmed operating status makes
 * the confidence moot, and the fixed defaults most providers use fall in
 * the range where this term is 0 anyway.
 */
export function confidencePrior(confidence: number | null, operatingStatus: string | null): number {
  if (operatingStatus !== null || confidence === null) {
    return 0;
  }
  if (confidence <= 0) {
    return MINIMUM_CONFIDENCE_PRIOR;
  }
  if (confidence >= 1) {
    return 0;
  }
  return Math.max(MINIMUM_CONFIDENCE_PRIOR, Math.min(0, logit(confidence)));
}

/** The record-quality part of the prior. */
export function qualityPrior(signals: PlaceQualitySignals): number {
  const dataset = signals.sourceDataset?.toLowerCase() ?? null;
  let prior = 0;
  if (dataset !== null && REGISTRY_FEEDS.has(dataset)) {
    prior += REGISTRY_FEED_PENALTY;
  }
  if (signals.taxonomyHierarchy.length < 2) {
    prior += UNCATEGORIZED_PENALTY;
  }
  if (
    dataset !== null &&
    DATED_PROVIDERS.has(dataset) &&
    signals.sourceUpdatedAt !== null &&
    signals.sourceUpdatedAt < STALE_SOURCE_BEFORE
  ) {
    prior += STALE_SOURCE_PENALTY;
  }
  prior += confidencePrior(signals.confidence, signals.operatingStatus);
  return prior;
}

/**
 * The prior an import stores: quality plus category, everything known from
 * the record itself. The corroboration bonus is added on top when read.
 */
export function importPrior(signals: PlaceQualitySignals): number {
  return qualityPrior(signals) + categoryPrior(signals.taxonomyHierarchy);
}

/**
 * What a venue gains for the providers beyond the first that matched it.
 * Null means the bridge files have not been read for this row yet, which
 * counts the same as a single provider. Mirrored in SQL by
 * `corroborationBonusSql` in places-search.ts.
 */
export function corroborationBonus(providerCount: number | null): number {
  const corroborating = Math.max((providerCount ?? 1) - 1, 0);
  return CORROBORATION_BONUS_PER_PROVIDER * Math.min(corroborating, MAXIMUM_CORROBORATING_PROVIDERS);
}

/** The prior as the app receives it: the stored one plus the corroboration bonus. */
export function placePrior(signals: PlaceQualitySignals, providerCount: number | null): number {
  return importPrior(signals) + corroborationBonus(providerCount);
}
