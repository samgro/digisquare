//
//  PlaceCategory.swift
//  Hackysack
//

import Foundation

/// An Overture place category with a name fit for a label. The list is a
/// curated slice of Overture's taxonomy (which runs to over two thousand
/// codes) for the category picker on a new venue; anything outside it is
/// still displayed, just with a name made from its code.
nonisolated struct PlaceCategory: Identifiable, Hashable, Sendable {
    /// The Overture category code, as stored on a place: `coffee_shop`.
    let code: String
    let displayName: String

    var id: String { code }

    static let all: [PlaceCategory] = [
        PlaceCategory(code: "airport", displayName: "Airport"),
        PlaceCategory(code: "art_gallery", displayName: "Art Gallery"),
        PlaceCategory(code: "bakery", displayName: "Bakery"),
        PlaceCategory(code: "bar", displayName: "Bar"),
        PlaceCategory(code: "beach", displayName: "Beach"),
        PlaceCategory(code: "bookstore", displayName: "Bookstore"),
        PlaceCategory(code: "brewery", displayName: "Brewery"),
        PlaceCategory(code: "bus_station", displayName: "Bus Station"),
        PlaceCategory(code: "cafe", displayName: "Cafe"),
        PlaceCategory(code: "campground", displayName: "Campground"),
        PlaceCategory(code: "church_cathedral", displayName: "Church"),
        PlaceCategory(code: "cinema", displayName: "Movie Theater"),
        PlaceCategory(code: "clothing_store", displayName: "Clothing Store"),
        PlaceCategory(code: "coffee_shop", displayName: "Coffee Shop"),
        PlaceCategory(code: "college_university", displayName: "College or University"),
        PlaceCategory(code: "community_center", displayName: "Community Center"),
        PlaceCategory(code: "convenience_store", displayName: "Convenience Store"),
        PlaceCategory(code: "corporate_office", displayName: "Office"),
        PlaceCategory(code: "coworking_space", displayName: "Coworking Space"),
        PlaceCategory(code: "dentist", displayName: "Dentist"),
        PlaceCategory(code: "dog_park", displayName: "Dog Park"),
        PlaceCategory(code: "ev_charging_station", displayName: "EV Charging Station"),
        PlaceCategory(code: "farmers_market", displayName: "Farmers Market"),
        PlaceCategory(code: "florist", displayName: "Florist"),
        PlaceCategory(code: "food_truck", displayName: "Food Truck"),
        PlaceCategory(code: "gas_station", displayName: "Gas Station"),
        PlaceCategory(code: "golf_course", displayName: "Golf Course"),
        PlaceCategory(code: "grocery_store", displayName: "Grocery Store"),
        PlaceCategory(code: "gym", displayName: "Gym"),
        PlaceCategory(code: "hardware_store", displayName: "Hardware Store"),
        PlaceCategory(code: "hiking_trail", displayName: "Hiking Trail"),
        PlaceCategory(code: "hospital", displayName: "Hospital"),
        PlaceCategory(code: "hotel", displayName: "Hotel"),
        PlaceCategory(code: "ice_cream_shop", displayName: "Ice Cream Shop"),
        PlaceCategory(code: "landmark_and_historical_building", displayName: "Landmark"),
        PlaceCategory(code: "library", displayName: "Library"),
        PlaceCategory(code: "light_rail_and_subway_stations", displayName: "Subway Station"),
        PlaceCategory(code: "liquor_store", displayName: "Liquor Store"),
        PlaceCategory(code: "marina", displayName: "Marina"),
        PlaceCategory(code: "monument", displayName: "Monument"),
        PlaceCategory(code: "museum", displayName: "Museum"),
        PlaceCategory(code: "music_venue", displayName: "Music Venue"),
        PlaceCategory(code: "park", displayName: "Park"),
        PlaceCategory(code: "parking", displayName: "Parking"),
        PlaceCategory(code: "pharmacy", displayName: "Pharmacy"),
        PlaceCategory(code: "plaza", displayName: "Plaza"),
        PlaceCategory(code: "pub", displayName: "Pub"),
        PlaceCategory(code: "restaurant", displayName: "Restaurant"),
        PlaceCategory(code: "school", displayName: "School"),
        PlaceCategory(code: "shopping_center", displayName: "Shopping Center"),
        PlaceCategory(code: "ski_resort", displayName: "Ski Resort"),
        PlaceCategory(code: "sports_and_recreation_venue", displayName: "Sports Venue"),
        PlaceCategory(code: "stadium_arena", displayName: "Stadium"),
        PlaceCategory(code: "supermarket", displayName: "Supermarket"),
        PlaceCategory(code: "swimming_pool", displayName: "Swimming Pool"),
        PlaceCategory(code: "tennis_court", displayName: "Tennis Court"),
        PlaceCategory(code: "theatre", displayName: "Theater"),
        PlaceCategory(code: "town_hall", displayName: "Town Hall"),
        PlaceCategory(code: "train_station", displayName: "Train Station"),
        PlaceCategory(code: "wine_bar", displayName: "Wine Bar"),
        PlaceCategory(code: "winery", displayName: "Winery"),
        PlaceCategory(code: "yoga_studio", displayName: "Yoga Studio"),
    ]

    private static let byCode: [String: PlaceCategory] = Dictionary(
        all.map { ($0.code, $0) },
        uniquingKeysWith: { first, _ in first }
    )

    /// The curated name when there is one, otherwise the code made readable:
    /// "mexican_restaurant" → "Mexican Restaurant".
    static func displayName(for code: String) -> String {
        if let category = byCode[code] {
            return category.displayName
        }
        return code
            .split(separator: "_")
            .map { $0.capitalized }
            .joined(separator: " ")
    }
}
