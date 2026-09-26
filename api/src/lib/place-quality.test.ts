import { describe, expect, it } from "vitest";
import {
  CATEGORY_BOOST,
  CATEGORY_PENALTY,
  categoryPrior,
  confidencePrior,
  corroborationBonus,
  HIDDEN_PRIOR_THRESHOLD,
  importPrior,
  placePrior,
  type PlaceQualitySignals,
} from "./place-quality.js";

function signals(overrides: Partial<PlaceQualitySignals> = {}): PlaceQualitySignals {
  return {
    sourceDataset: "meta",
    confidence: 0.99,
    operatingStatus: "open",
    taxonomyHierarchy: ["food_and_drink", "restaurant", "latin_american_restaurant", "mexican_restaurant"],
    sourceUpdatedAt: new Date("2026-09-14T00:00:00Z"),
    ...overrides,
  };
}

describe("categoryPrior", () => {
  it("boosts food, drink, lodging and venues", () => {
    expect(categoryPrior(["food_and_drink", "restaurant", "mexican_restaurant"])).toBe(CATEGORY_BOOST);
    expect(categoryPrior(["food_and_drink", "casual_eatery", "bakery"])).toBe(CATEGORY_BOOST);
    expect(categoryPrior(["lodging", "hotel"])).toBe(CATEGORY_BOOST);
    expect(categoryPrior(["arts_and_entertainment", "museum", "art_museum"])).toBe(CATEGORY_BOOST);
    expect(categoryPrior(["sports_and_recreation", "park"])).toBe(CATEGORY_BOOST);
    expect(categoryPrior(["community_and_government", "government_office", "town_hall"])).toBe(CATEGORY_BOOST);
    expect(categoryPrior(["community_and_government", "government_office", "department_of_motor_vehicles"])).toBe(0);
    expect(categoryPrior(["travel_and_transportation", "air_transport_facility_or_service", "airport"])).toBe(
      CATEGORY_BOOST,
    );
  });

  it("penalizes offices, practitioners and services", () => {
    expect(categoryPrior(["services_and_business", "financial_service", "mortgage_lender"])).toBe(CATEGORY_PENALTY);
    expect(categoryPrior(["services_and_business", "legal_service", "attorney_or_law_firm"])).toBe(CATEGORY_PENALTY);
    expect(categoryPrior(["health_care", "outpatient_care_facility", "behavioral_or_mental_health_clinic", "counseling"])).toBe(
      CATEGORY_PENALTY,
    );
    expect(categoryPrior(["travel_and_transportation", "travel_service"])).toBe(CATEGORY_PENALTY);
    expect(categoryPrior(["community_and_government", "social_or_community_service"])).toBe(CATEGORY_PENALTY);
  });

  it("lets a deeper entry carve an exception out of its parent", () => {
    expect(categoryPrior(["services_and_business", "financial_service", "bank_or_credit_union", "bank"])).toBe(0);
    expect(categoryPrior(["services_and_business", "financial_service", "atm"])).toBe(CATEGORY_PENALTY);
    expect(categoryPrior(["services_and_business", "rental_service", "car_rental_service"])).toBe(0);
    expect(categoryPrior(["health_care", "hospital"])).toBe(0);
    expect(categoryPrior(["lodging", "private_lodging", "vacation_rental"])).toBe(0);
    expect(categoryPrior(["travel_and_transportation", "ground_transport_facility_or_service", "train_station"])).toBe(
      CATEGORY_BOOST,
    );
    expect(categoryPrior(["travel_and_transportation", "ground_transport_facility_or_service", "taxi_service"])).toBe(
      CATEGORY_PENALTY,
    );
  });

  it("is neutral for shops, salons, parking and anything unlisted", () => {
    expect(categoryPrior(["shopping", "fashion_and_apparel_store", "clothing_store"])).toBe(0);
    expect(categoryPrior(["lifestyle_services", "personal_or_beauty_service", "nail_salon"])).toBe(0);
    expect(categoryPrior(["travel_and_transportation", "parking"])).toBe(0);
    expect(categoryPrior([])).toBe(0);
  });
});

describe("confidencePrior", () => {
  it("is the floored log-odds of an unconfirmed record's confidence, never a gain", () => {
    expect(confidencePrior(0.19, null)).toBeCloseTo(-1.45, 2);
    expect(confidencePrior(0.5, null)).toBe(0);
    expect(confidencePrior(0.99, null)).toBe(0);
    expect(confidencePrior(0.01, null)).toBe(-3);
    expect(confidencePrior(0, null)).toBe(-3);
    expect(confidencePrior(1, null)).toBe(0);
  });

  it("is moot once a provider confirmed the operating status", () => {
    expect(confidencePrior(0.19, "open")).toBe(0);
    expect(confidencePrior(0.19, "temporarily_closed")).toBe(0);
    expect(confidencePrior(null, null)).toBe(0);
  });
});

describe("importPrior", () => {
  it("gives a confirmed, categorized restaurant its category boost and nothing else", () => {
    expect(importPrior(signals())).toBe(CATEGORY_BOOST);
  });

  it("penalizes a registry record, and hides one with no real category", () => {
    // "Miguel Inc", a BrightQuery "restaurant" 4 m from La Taqueria.
    const shellCompany = signals({
      sourceDataset: "BrightQuery",
      confidence: 0.95,
      taxonomyHierarchy: ["food_and_drink", "restaurant"],
    });
    expect(importPrior(shellCompany)).toBe(-2 + CATEGORY_BOOST);

    // "Jesus Gabriel Yanez", a BrightQuery record categorized only as health_care.
    const personRecord = signals({
      sourceDataset: "BrightQuery",
      confidence: 0.95,
      taxonomyHierarchy: ["health_care"],
    });
    expect(importPrior(personRecord)).toBe(-2 - 3 + CATEGORY_PENALTY);
    expect(importPrior(personRecord)).toBeLessThan(HIDDEN_PRIOR_THRESHOLD);
    expect(importPrior(shellCompany)).toBeGreaterThanOrEqual(HIDDEN_PRIOR_THRESHOLD);
  });

  it("penalizes an uncategorized record whoever it came from", () => {
    expect(importPrior(signals({ taxonomyHierarchy: [] }))).toBe(-3);
  });

  it("uses the confidence only when the status is unconfirmed", () => {
    const unconfirmed = signals({ confidence: 0.19, operatingStatus: null, taxonomyHierarchy: ["lodging", "hotel"] });
    expect(importPrior(unconfirmed)).toBeCloseTo(CATEGORY_BOOST - 1.45, 2);
    expect(importPrior(signals({ confidence: 0.19 }))).toBe(CATEGORY_BOOST);
  });

  it("penalizes a Microsoft or Foursquare record nobody has verified for years", () => {
    // "Chase Mortgage": a Microsoft record last updated in 2016.
    const stale = signals({
      sourceDataset: "Microsoft",
      sourceUpdatedAt: new Date("2016-04-12T00:00:00Z"),
      taxonomyHierarchy: ["services_and_business", "financial_service", "mortgage_lender"],
    });
    expect(importPrior(stale)).toBe(-1 + CATEGORY_PENALTY);
    expect(importPrior(signals({ sourceDataset: "Foursquare", sourceUpdatedAt: new Date("2025-06-01T00:00:00Z") }))).toBe(
      CATEGORY_BOOST,
    );
    // Meta's date is the feed delivery, so an old one says nothing.
    expect(importPrior(signals({ sourceDataset: "meta", sourceUpdatedAt: new Date("2016-04-12T00:00:00Z") }))).toBe(
      CATEGORY_BOOST,
    );
  });
});

describe("corroborationBonus", () => {
  it("rewards each provider beyond the first, up to two", () => {
    expect(corroborationBonus(null)).toBe(0);
    expect(corroborationBonus(1)).toBe(0);
    expect(corroborationBonus(2)).toBe(0.5);
    expect(corroborationBonus(3)).toBe(1);
    expect(corroborationBonus(5)).toBe(1);
  });

  it("is added to the stored prior when a place is read", () => {
    expect(placePrior(signals(), 2)).toBe(CATEGORY_BOOST + 0.5);
  });
});
