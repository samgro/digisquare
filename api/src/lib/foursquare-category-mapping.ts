import { OVERTURE_CATEGORIES } from "./overture-categories.js";

/**
 * Reconciles Foursquare's category taxonomy with Overture's, so a Swarm
 * checkin's venue can be stored with the `primaryType` and `types` every
 * other place has and the app already knows how to draw and label.
 *
 * Foursquare publishes no mapping to Overture, so a category resolves in
 * three steps, each tried on the category itself and then on each ancestor in
 * turn: a hand-written entry below, then its name turned into a code
 * ("Ramen Restaurant" → `ramen_restaurant`) when Overture has that exact
 * code, then the same for its parent. So a "Hotpot Restaurant" lands on
 * `asian_restaurant` and an unmapped retail leaf on `shopping`. The exact
 * Foursquare name is kept separately in `categoryName`, so nothing is lost by
 * landing on a broader Overture category, and a category Overture has no
 * counterpart for at all still shows its own label.
 *
 * The table covers the top-level categories, the mid-level groups beneath
 * them, and the leaves people check in to most. Keyed by Foursquare's 24-hex
 * category id, which is stable across renames. Every value is a code from the
 * taxonomy in overture-categories.ts (a test checks). A `null` entry means
 * "no Overture category, and stop looking": a private home is nobody's
 * business as an apartment or a government building.
 */
export const OVERTURE_CATEGORY_BY_FOURSQUARE_CATEGORY_ID: Readonly<Record<string, string | null>> = {
  // Top-level categories: the fallback for anything deeper that is unmapped.
  // Landmarks and Outdoors is left out on purpose: a mountain, a plaza and a
  // lighthouse have nothing in common that Overture names, so its leaves
  // resolve on their own names or not at all. Business and Professional
  // Services is too broad in the same way.
  "4d4b7104d754a06370d81259": "arts_and_entertainment", // Arts and Entertainment
  "63be6904847c3692a84b9b9a": "community_and_government", // Community and Government
  "63be6904847c3692a84b9bb5": "food_and_drink", // Dining and Drinking
  "4d4b7105d754a06373d81259": "event_venue", // Event
  "63be6904847c3692a84b9bb9": "health_care", // Health and Medicine
  "4d4b7105d754a06378d81259": "shopping", // Retail
  "4f4528bc4b90abdf24c9de85": "sports_and_recreation", // Sports and Recreation
  "4d4b7105d754a06379d81259": "travel_and_transportation", // Travel and Transportation

  // Dining and Drinking
  "4d4b7105d754a06374d81259": "restaurant", // Restaurant
  "63be6904847c3692a84b9bb6": "cafe", // Cafe, Coffee, and Tea House
  "4bf58dd8d48988d1e0931735": "coffee_shop", // Coffee Shop
  "4bf58dd8d48988d16d941735": "cafe", // Café
  "4bf58dd8d48988d1dc931735": "tea_room", // Tea Room
  "4bf58dd8d48988d116941735": "bar", // Bar
  "4bf58dd8d48988d11b941735": "pub", // Pub
  "4bf58dd8d48988d123941735": "wine_bar", // Wine Bar
  "50327c8591d4c4b30a586d5d": "brewery", // Brewery
  "4bf58dd8d48988d14b941735": "winery", // Winery
  "4bf58dd8d48988d16a941735": "bakery", // Bakery
  "4bf58dd8d48988d179941735": "bagel_shop", // Bagel Shop
  "4bf58dd8d48988d143941735": "breakfast_and_brunch_restaurant", // Breakfast Spot
  "4bf58dd8d48988d1d0941735": "dessert_shop", // Dessert Shop
  "4bf58dd8d48988d1c9941735": "ice_cream_shop", // Ice Cream Parlor
  "4bf58dd8d48988d148941735": "donut_shop", // Donut Shop
  "4bf58dd8d48988d112941735": "smoothie_juice_bar", // Juice Bar
  "4bf58dd8d48988d120951735": "food_court", // Food Court
  "4bf58dd8d48988d1cb941735": "food_truck_stand", // Food Truck
  "4bf58dd8d48988d142941735": "asian_restaurant", // Asian Restaurant
  "4bf58dd8d48988d145941735": "chinese_restaurant", // Chinese Restaurant
  "4bf58dd8d48988d111941735": "japanese_restaurant", // Japanese Restaurant
  "4bf58dd8d48988d1d2941735": "sushi_restaurant", // Sushi Restaurant
  "55a59bace4b013909087cb24": "ramen_restaurant", // Ramen Restaurant
  "4bf58dd8d48988d113941735": "korean_restaurant", // Korean Restaurant
  "4bf58dd8d48988d149941735": "thai_restaurant", // Thai Restaurant
  "4bf58dd8d48988d14a941735": "vietnamese_restaurant", // Vietnamese Restaurant
  "4bf58dd8d48988d10f941735": "indian_restaurant", // Indian Restaurant
  "4bf58dd8d48988d1c1941735": "mexican_restaurant", // Mexican Restaurant
  "4bf58dd8d48988d110941735": "italian_restaurant", // Italian Restaurant
  "4bf58dd8d48988d1ca941735": "pizza_restaurant", // Pizzeria
  "4bf58dd8d48988d10c941735": "french_restaurant", // French Restaurant
  "4bf58dd8d48988d1c0941735": "mediterranean_restaurant", // Mediterranean Restaurant
  "4bf58dd8d48988d14e941735": "american_restaurant", // American Restaurant
  "4bf58dd8d48988d16c941735": "burger_restaurant", // Burger Joint
  "4bf58dd8d48988d16e941735": "fast_food_restaurant", // Fast Food Restaurant
  "4bf58dd8d48988d1c5941735": "sandwich_shop", // Sandwich Spot
  "4bf58dd8d48988d147941735": "diner", // Diner
  "4bf58dd8d48988d1cc941735": "steakhouse", // Steakhouse
  "4bf58dd8d48988d1ce941735": "seafood_restaurant", // Seafood Restaurant
  "4bf58dd8d48988d1d3941735": "vegetarian_restaurant", // Vegan and Vegetarian Restaurant

  // Arts and Entertainment
  "4bf58dd8d48988d11f941735": "dance_club", // Night Club
  "4bf58dd8d48988d17f941735": "movie_theater", // Movie Theater
  "4bf58dd8d48988d1f2931735": "performing_arts_venue", // Performing Arts Venue
  "5032792091d4c4b30a586d5c": "music_venue", // Concert Hall
  "4bf58dd8d48988d181941735": "museum", // Museum
  "4bf58dd8d48988d1e2931735": "art_gallery", // Art Gallery
  "4bf58dd8d48988d184941735": "stadium_arena", // Stadium
  "4bf58dd8d48988d182941735": "amusement_park", // Amusement Park
  "4bf58dd8d48988d17b941735": "zoo", // Zoo
  "4fceea171983d5d06c3e9823": "aquarium", // Aquarium
  "4bf58dd8d48988d1e4931735": "bowling_alley", // Bowling Alley
  "4bf58dd8d48988d17c941735": "casino", // Casino

  // Landmarks and Outdoors
  "4bf58dd8d48988d163941735": "park", // Park
  "4bf58dd8d48988d1e5941735": "dog_park", // Dog Park
  "4bf58dd8d48988d1e7941735": "playground", // Playground
  "52e81612bcbc57f1066b7a21": "national_park", // National Park
  "52e81612bcbc57f1066b7a22": "botanical_garden", // Botanical Garden
  "4bf58dd8d48988d159941735": "hiking_trail", // Hiking Trail
  "4bf58dd8d48988d1e2941735": "beach", // Beach
  "4bf58dd8d48988d1e4941735": "campground", // Campground
  "4bf58dd8d48988d1e0941735": "marina", // Harbor or Marina
  "4bf58dd8d48988d164941735": "public_plaza", // Plaza
  "4bf58dd8d48988d165941735": "lookout", // Scenic Lookout

  // Retail
  "4bf58dd8d48988d1f9941735": "grocery_store", // Food and Beverage Retail
  "4bf58dd8d48988d118951735": "grocery_store", // Grocery Store
  "52f2ab2ebcbc57f1066b8b46": "grocery_store", // Supermarket
  "4bf58dd8d48988d186941735": "liquor_store", // Liquor Store
  "4bf58dd8d48988d1fa941735": "farmers_market", // Farmers Market
  "50be8ee891d4fa8dcc7199a7": "public_market", // Market
  "4d954b0ea243a5684a65b473": "convenience_store", // Convenience Store
  "63be6904847c3692a84b9bec": "clothing_store", // Fashion Retail
  "4bf58dd8d48988d1fd941735": "shopping_mall", // Shopping Mall
  "4bf58dd8d48988d114951735": "bookstore", // Bookstore
  "4bf58dd8d48988d112951735": "hardware_store", // Hardware Store
  "63be6904847c3692a84b9bea": "electronics_store", // Computers and Electronics Retail
  "4bf58dd8d48988d10f951735": "pharmacy", // Pharmacy
  "5745c2e4498e11e7bccabdbd": "drugstore", // Drugstore

  // Sports and Recreation
  "4bf58dd8d48988d175941735": "gym", // Gym and Studio
  "4bf58dd8d48988d176941735": "gym", // Gym
  "4bf58dd8d48988d102941735": "yoga_studio", // Yoga Studio
  "4bf58dd8d48988d15e941735": "swimming_pool", // Swimming Pool
  "4bf58dd8d48988d1e6941735": "golf_course", // Golf Course
  "4bf58dd8d48988d1e9941735": "ski_resort", // Ski Resort and Area

  // Travel and Transportation
  "63be6904847c3692a84b9c25": "lodging", // Lodging
  "4bf58dd8d48988d1fa931735": "hotel", // Hotel
  "4bf58dd8d48988d1ee931735": "hostel", // Hostel
  "4bf58dd8d48988d1fb931735": "motel", // Motel
  "63be6904847c3692a84b9c28": "public_transit_facility_or_service", // Transport Hub
  "4bf58dd8d48988d1ed931735": "airport", // Airport
  "4bf58dd8d48988d129951735": "train_station", // Rail Station
  "4bf58dd8d48988d1fd931735": "metro_station", // Metro Station
  "4bf58dd8d48988d1fc931735": "light_rail_and_subway_station", // Light Rail Station
  "4bf58dd8d48988d1fe931735": "bus_station", // Bus Station
  "52f2ab2ebcbc57f1066b8b4f": "bus_station", // Bus Stop
  "4bf58dd8d48988d113951735": "gas_station", // Fuel Station
  "4c38df4de52ce0d596b336e1": "parking", // Parking

  // Business and Professional Services
  "4bf58dd8d48988d124941735": "corporate_or_business_office", // Office
  "4bf58dd8d48988d171941735": "event_venue", // Event Space
  "63be6904847c3692a84b9b3f": "financial_service", // Banking and Finance
  "52f2ab2ebcbc57f1066b8b56": "atm", // ATM
  "4bf58dd8d48988d110951735": "hair_salon", // Hair Salon
  "63be6904847c3692a84b9b49": "barber", // Barbershop
  "4bf58dd8d48988d1ed941735": "spa", // Spa
  "52f2ab2ebcbc57f1066b8b33": "laundromat", // Laundromat

  // Community and Government
  "4bf58dd8d48988d12f941735": "library", // Library
  "4bf58dd8d48988d13b941735": "education", // Education
  "4d4b7105d754a06372d81259": "college_university", // College and University
  "4bf58dd8d48988d131941735": "place_of_worship", // Spiritual Center
  "4bf58dd8d48988d132941735": "christian_place_of_worship", // Church
  "4bf58dd8d48988d126941735": "government_office", // Government Building
  "4bf58dd8d48988d129941735": "town_hall", // City Hall
  "4bf58dd8d48988d172941735": "post_office", // Post Office
  // Where people live. Overture has no category for a home, and neither an
  // apartment building nor Community and Government is a fair stand-in.
  "4e67e38e036454776db1fb3a": null, // Residential Building
  "4bf58dd8d48988d103941735": null, // Home (private)

  // Health and Medicine
  "4bf58dd8d48988d196941735": "hospital", // Hospital
  "4bf58dd8d48988d178941735": "dental_clinic", // Dentist
  "4d954af4a243a5684765b473": "veterinarian", // Veterinarian
};

export interface CategoryNode {
  id: string;
  name: string;
  parentId: string | null;
}

/**
 * A Foursquare category name as an Overture code, if Overture has that exact
 * code: "Ramen Restaurant" → `ramen_restaurant`, "Café" → `cafe`. Null
 * otherwise; a guess Overture does not know is worse than no category.
 */
export function overtureCategoryCodeFromName(name: string): string | null {
  const code = name
    .normalize("NFD")
    .replace(/[̀-ͯ]/g, "")
    .toLowerCase()
    .replace(/\([^)]*\)/g, " ")
    .replace(/&/g, " and ")
    .replace(/[^a-z0-9]+/g, "_")
    .replace(/^_+|_+$/g, "");
  return code.length > 0 && OVERTURE_CATEGORIES.has(code) ? code : null;
}

/**
 * The Overture category for a Foursquare category: its own entry in the
 * table or its own name as a code, else the same for its nearest ancestor,
 * else null. `categoriesById` is the flattened tree, used to walk up and for
 * names; a category missing from it (Foursquare retired it) can still resolve
 * from its table entry or the name the venue carried.
 */
export function overtureCategoryForFoursquareCategory(
  category: { id: string; name?: string },
  categoriesById: ReadonlyMap<string, CategoryNode>,
): string | null {
  const visited = new Set<string>();
  let current: CategoryNode | undefined = categoriesById.get(category.id) ?? {
    id: category.id,
    name: category.name ?? "",
    parentId: null,
  };
  // The visited set guards against a malformed tree with a cycle.
  while (current && !visited.has(current.id)) {
    visited.add(current.id);
    if (Object.hasOwn(OVERTURE_CATEGORY_BY_FOURSQUARE_CATEGORY_ID, current.id)) {
      return OVERTURE_CATEGORY_BY_FOURSQUARE_CATEGORY_ID[current.id] ?? null;
    }
    const fromName = overtureCategoryCodeFromName(current.name);
    if (fromName) {
      return fromName;
    }
    current = current.parentId ? categoriesById.get(current.parentId) : undefined;
  }
  return null;
}
