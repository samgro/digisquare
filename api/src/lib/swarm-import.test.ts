import { describe, expect, it, vi } from "vitest";
import { createDatabaseStub } from "../../test/helpers/stub-database.js";
import { loadFoursquareFixture } from "../../test/helpers/fixtures.js";
import { flattenCategoryTree, type FoursquareCheckin } from "./foursquare.js";
import type { CategoryNode } from "./foursquare-category-mapping.js";

const { database } = createDatabaseStub();

vi.mock("../db/index.js", () => ({ database }));

const { toSwarmCheckinRows } = await import("./swarm-import.js");

const USER_ID = "550e8400-e29b-41d4-a716-446655440000";
const CHECKIN_ID = "880e8400-e29b-41d4-a716-446655440000";

const categoryFixture = loadFoursquareFixture("categories.json") as {
  response: { categories: Parameters<typeof flattenCategoryTree>[0] };
};
const categoriesById = new Map<string, CategoryNode>(
  flattenCategoryTree(categoryFixture.response.categories, null).map((category) => [
    category.id,
    category,
  ]),
);

const checkinFixture = loadFoursquareFixture("checkins-page.json") as {
  response: { checkins: { items: FoursquareCheckin[] } };
};
const [hotpotCheckin, homeCheckin] = checkinFixture.response.checkins.items as [
  FoursquareCheckin,
  FoursquareCheckin,
];

describe("toSwarmCheckinRows", () => {
  it("makes a places row from the venue with Overture categories and Foursquare's label", () => {
    const rows = toSwarmCheckinRows(hotpotCheckin, USER_ID, CHECKIN_ID, categoriesById);

    expect(rows.place).toEqual({
      source: "foursquare",
      foursquareVenueId: "4a8b9c0d1e2f3a4b5c6d7e8f",
      name: "Little Sheep",
      // The primary category wins, not the first listed; Overture has no
      // hotpot category, so it lands on the parent.
      primaryType: "asian_restaurant",
      types: ["asian_restaurant", "coffee_shop"],
      categoryName: "Hotpot Restaurant",
      addressStreet: "1655 Lincoln Ave",
      addressLocality: "San Jose",
      addressRegion: "US-CA",
      addressPostcode: "95125",
      addressCountry: "US",
      latitude: 37.3,
      longitude: -121.9,
    });
  });

  it("snapshots the checkin like one made here, keeping Swarm's id and details", () => {
    const rows = toSwarmCheckinRows(hotpotCheckin, USER_ID, CHECKIN_ID, categoriesById);

    expect(rows.checkin).toEqual({
      id: CHECKIN_ID,
      userId: USER_ID,
      source: "swarm",
      externalId: "5f1a2b3c4d5e6f7a8b9c0d1e",
      placeName: "Little Sheep",
      placeAddress: "1655 Lincoln Ave, San Jose, CA 95125, US",
      placeLocality: "San Jose",
      placeRegion: "US-CA",
      placeCountry: "US",
      placePrimaryType: "asian_restaurant",
      placeTypes: ["asian_restaurant", "coffee_shop"],
      placeCategoryName: "Hotpot Restaurant",
      latitude: 37.3,
      longitude: -121.9,
      message: "Hotpot night",
      visibility: "friends",
      timeZoneOffsetMinutes: -420,
      createdAt: new Date(1600000000 * 1000),
    });
    expect(rows.venue).toMatchObject({
      id: "4a8b9c0d1e2f3a4b5c6d7e8f",
      city: "San Jose",
      state: "CA",
      countryCode: "US",
      crossStreet: "at Main St",
      primaryCategoryId: "52af0bd33cf9994f4e043bdd",
      categoryIds: ["4bf58dd8d48988d1e0931735", "52af0bd33cf9994f4e043bdd"],
    });
  });

  it("keeps photos in order with their full-size source url", () => {
    const rows = toSwarmCheckinRows(hotpotCheckin, USER_ID, CHECKIN_ID, categoriesById);

    expect(rows.photos).toEqual([
      {
        checkinId: CHECKIN_ID,
        position: 0,
        sourceUrl: "https://fastly.4sqi.net/img/general/original/1234_first.jpg",
        externalId: "5f1a2b3c4d5e6f7a8b9c0d20",
        width: 1440,
        height: 1920,
      },
      {
        checkinId: CHECKIN_ID,
        position: 1,
        sourceUrl: "https://fastly.4sqi.net/img/general/original/1234_second.jpg",
        externalId: "5f1a2b3c4d5e6f7a8b9c0d21",
        width: 1920,
        height: 1440,
      },
    ]);
  });

  it("imports a private home as private, with no Overture category but its own label", () => {
    const rows = toSwarmCheckinRows(homeCheckin, USER_ID, CHECKIN_ID, categoriesById);

    expect(rows.checkin.visibility).toBe("private");
    expect(rows.checkin.message).toBeNull();
    expect(rows.checkin.placeAddress).toBeNull();
    expect(rows.checkin.timeZoneOffsetMinutes).toBeNull();
    expect(rows.checkin.placePrimaryType).toBeNull();
    expect(rows.checkin.placeCategoryName).toBe("Home (private)");
    expect(rows.place).toMatchObject({ primaryType: null, types: [], categoryName: "Home (private)" });
    expect(rows.photos).toEqual([]);
  });
});
