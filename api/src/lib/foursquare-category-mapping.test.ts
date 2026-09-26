import { describe, expect, it } from "vitest";
import { loadFoursquareFixture } from "../../test/helpers/fixtures.js";
import { flattenCategoryTree } from "./foursquare.js";
import {
  OVERTURE_CATEGORY_BY_FOURSQUARE_CATEGORY_ID,
  overtureCategoryCodeFromName,
  overtureCategoryForFoursquareCategory,
  type CategoryNode,
} from "./foursquare-category-mapping.js";
import { OVERTURE_CATEGORIES } from "./overture-categories.js";

const categoryFixture = loadFoursquareFixture("categories.json") as {
  response: { categories: Parameters<typeof flattenCategoryTree>[0] };
};
const categoriesById = new Map<string, CategoryNode>(
  flattenCategoryTree(categoryFixture.response.categories, null).map((category) => [
    category.id,
    category,
  ]),
);

describe("OVERTURE_CATEGORY_BY_FOURSQUARE_CATEGORY_ID", () => {
  it("only names categories the Overture taxonomy has", () => {
    const unknown = Object.entries(OVERTURE_CATEGORY_BY_FOURSQUARE_CATEGORY_ID)
      .filter(([, overtureCategory]) => overtureCategory !== null && !OVERTURE_CATEGORIES.has(overtureCategory))
      .map(([foursquareCategoryId, overtureCategory]) => `${foursquareCategoryId} → ${overtureCategory}`);
    expect(unknown).toEqual([]);
  });
});

describe("overtureCategoryCodeFromName", () => {
  it("turns a Foursquare name into the matching Overture code", () => {
    expect(overtureCategoryCodeFromName("Ramen Restaurant")).toBe("ramen_restaurant");
    expect(overtureCategoryCodeFromName("Café")).toBe("cafe");
    expect(overtureCategoryCodeFromName("Bed & Breakfast")).toBe("bed_and_breakfast");
  });

  it("is null for a name Overture has no code for", () => {
    expect(overtureCategoryCodeFromName("Hotpot Restaurant")).toBeNull();
    expect(overtureCategoryCodeFromName("Home (private)")).toBeNull();
    expect(overtureCategoryCodeFromName("")).toBeNull();
  });
});

describe("overtureCategoryForFoursquareCategory", () => {
  it("uses a category's own mapping", () => {
    expect(
      overtureCategoryForFoursquareCategory({ id: "4bf58dd8d48988d1e0931735" }, categoriesById),
    ).toBe("coffee_shop");
  });

  it("falls back to the nearest ancestor with a mapping", () => {
    // Hotpot Restaurant → Asian Restaurant.
    expect(
      overtureCategoryForFoursquareCategory({ id: "52af0bd33cf9994f4e043bdd" }, categoriesById),
    ).toBe("asian_restaurant");
  });

  it("derives a code from a name the table does not list", () => {
    const tree = new Map<string, CategoryNode>([
      ["parent", { id: "parent", name: "Restaurant", parentId: null }],
      ["leaf", { id: "leaf", name: "Dim Sum Restaurant", parentId: "parent" }],
    ]);
    expect(overtureCategoryForFoursquareCategory({ id: "leaf" }, tree)).toBe("dim_sum_restaurant");
  });

  it("uses the name a venue carried for a category missing from the tree", () => {
    expect(
      overtureCategoryForFoursquareCategory({ id: "retired", name: "Taiwanese Restaurant" }, categoriesById),
    ).toBe("taiwanese_restaurant");
    expect(overtureCategoryForFoursquareCategory({ id: "retired" }, categoriesById)).toBeNull();
  });

  it("stops at a category deliberately mapped to nothing", () => {
    // Home (private) sits under Residential Building under Community and
    // Government, which is mapped; a home must not become a government office.
    expect(
      overtureCategoryForFoursquareCategory({ id: "4bf58dd8d48988d103941735" }, categoriesById),
    ).toBeNull();
  });

  it("survives a cycle in a malformed tree", () => {
    const cyclic = new Map<string, CategoryNode>([
      ["a", { id: "a", name: "Nothing Known", parentId: "b" }],
      ["b", { id: "b", name: "Nor This", parentId: "a" }],
    ]);
    expect(overtureCategoryForFoursquareCategory({ id: "a" }, cyclic)).toBeNull();
  });
});
