//
//  PlaceFootprint.swift
//  Hackysack
//

import Foundation

/// Flat-earth distance helpers for the ranker. Equirectangular is accurate to
/// well under a meter at the few kilometers involved here, and it keeps the
/// ranker free of CoreLocation so it can run anywhere, including unit tests.
nonisolated enum GeoDistance {
    static let metersPerDegreeLatitude = 111_320.0

    static func meters(from origin: PlaceLocation, to destination: PlaceLocation) -> Double {
        let north = (destination.latitude - origin.latitude) * metersPerDegreeLatitude
        let east = (destination.longitude - origin.longitude) * metersPerDegreeLongitude(atLatitude: origin.latitude)
        return (north * north + east * east).squareRoot()
    }

    static func metersPerDegreeLongitude(atLatitude latitude: Double) -> Double {
        metersPerDegreeLatitude * cos(latitude * .pi / 180)
    }
}

/// How a venue's size should be treated when scoring it.
nonisolated enum PlaceFootprintClass: Sendable {
    /// A storefront: the pin is where you are when you are there.
    case point
    /// A large venue that is usually the canonical checkin when you are inside
    /// it (an airport, a stadium). Pays a small price for its size.
    case destination
    /// A large venue whose sub-venues are usually the intended checkin (a park
    /// with a museum in it, a mall with stores). Pays the full price for its
    /// size so the museum or the store can win.
    case container
}

/// The physical extent of a place, used to turn "distance to the pin" into
/// "distance to the venue".
///
/// Overture places are points, so the extent is a guess from the category:
/// every airport is modeled as a 1.5 km disc, every park as a 150 m one. That
/// finds the airport from a terminal gate, but it also means a regional
/// airfield's disc covers the town next to it, and a city park the size of
/// Golden Gate Park is treated as a neighborhood one. Recording real extents
/// (Overture's base theme has the polygons) is the way to do better.
nonisolated struct PlaceFootprint: Sendable {
    /// Half the venue's extent in meters.
    let radius: Double
    let kind: PlaceFootprintClass

    /// Storefront radius. Generous on purpose: pins are often a shop width
    /// off, and the user is somewhere inside the shop, not at the pin.
    static let pointRadius = 25.0

    private struct TableEntry {
        let radius: Double
        let kind: PlaceFootprintClass
    }

    /// Keyed by Overture category code.
    private static let table: [String: TableEntry] = [
        "airport": TableEntry(radius: 1500, kind: .destination),
        "college_university": TableEntry(radius: 600, kind: .destination),
        "amusement_park": TableEntry(radius: 600, kind: .destination),
        "zoo": TableEntry(radius: 600, kind: .destination),
        "ski_resort": TableEntry(radius: 600, kind: .destination),
        "ski_area": TableEntry(radius: 600, kind: .destination),
        "golf_course": TableEntry(radius: 600, kind: .destination),
        "national_park": TableEntry(radius: 600, kind: .destination),
        "state_park": TableEntry(radius: 600, kind: .destination),
        "stadium_arena": TableEntry(radius: 300, kind: .destination),
        "airport_terminal": TableEntry(radius: 300, kind: .container),
        "park": TableEntry(radius: 150, kind: .container),
        "shopping_center": TableEntry(radius: 150, kind: .container),
        "train_station": TableEntry(radius: 150, kind: .container),
        "public_transportation": TableEntry(radius: 150, kind: .container),
        "light_rail_and_subway_stations": TableEntry(radius: 150, kind: .container),
        "hospital": TableEntry(radius: 150, kind: .container),
        "sports_and_recreation_venue": TableEntry(radius: 150, kind: .container),
        "convention_and_exhibition_center": TableEntry(radius: 150, kind: .container),
        "campground": TableEntry(radius: 150, kind: .container),
        "marina": TableEntry(radius: 150, kind: .container),
        "botanical_garden": TableEntry(radius: 150, kind: .container),
        "nature_reserve": TableEntry(radius: 150, kind: .container),
        // The building is the checkin; the listings inside are its offices.
        "town_hall": TableEntry(radius: 60, kind: .destination),
        "courthouse": TableEntry(radius: 60, kind: .destination),
        "hotel": TableEntry(radius: 60, kind: .container),
        "resort": TableEntry(radius: 60, kind: .container),
        "museum": TableEntry(radius: 60, kind: .container),
        "school": TableEntry(radius: 60, kind: .container),
        "local_and_state_government_offices": TableEntry(radius: 60, kind: .container),
        "garden": TableEntry(radius: 60, kind: .container),
        "plaza": TableEntry(radius: 60, kind: .container),
        "public_plaza": TableEntry(radius: 60, kind: .container),
        "community_center": TableEntry(radius: 60, kind: .container),
    ]

    /// Overture has a category per kind of museum and stadium
    /// (`art_museum`, `soccer_stadium`, ...); these fold them onto the
    /// generic entry.
    private static let suffixTable: [(suffix: String, entry: TableEntry)] = [
        ("_museum", table["museum"]!),
        ("_stadium", table["stadium_arena"]!),
        ("_airports", table["airport"]!),
    ]

    /// Log-prior adjustments for place types that a nearest-first search
    /// surfaces at 5 m but almost nobody means to check in at. Penalties only,
    /// so the places stay in the list for the rare time they are wanted.
    private static let typePriors: [String: Double] = [
        "parking": -1.5,
        "bike_parking": -1.5,
        "motorcycle_parking": -1.5,
        "public_restrooms": -1.5,
        "ev_charging_station": -1.0,
        // Offices listed inside a building someone would actually check in at:
        // a town hall's departments, the startups registered at a coworking
        // address. Recorded fixtures have a dozen of these within 25 m.
        "government_services": -1.0,
        "local_and_state_government_offices": -1.0,
        "corporate_office": -1.0,
        "public_and_government_association": -1.0,
        "non_governmental_association": -1.0,
        "professional_services": -1.0,
        "financial_service": -1.0,
        "atms": -1.0,
        "bus_station": -0.5,
        "self_storage_facility": -0.5,
        "storage_facility": -0.5,
    ]

    private static func tableEntry(for category: String) -> TableEntry? {
        if let entry = table[category] {
            return entry
        }
        return suffixTable.first { category.hasSuffix($0.suffix) }?.entry
    }

    /// Judged on the primary category alone when there is one: a restaurant
    /// whose alternates include `airport` is a restaurant in an airport, and
    /// a town hall that is also tagged `local_and_state_government_offices`
    /// must not be penalized as one of its own departments. Only a place
    /// with no primary category is judged on its alternates.
    static func lookup<Value>(for place: Place, _ resolve: (String) -> Value?) -> Value? {
        if let primaryType = place.primaryType {
            return resolve(primaryType)
        }
        for type in place.types {
            if let value = resolve(type) {
                return value
            }
        }
        return nil
    }

    static func typePrior(for place: Place) -> Double {
        lookup(for: place) { typePriors[$0] } ?? 0
    }

    init(for place: Place) {
        let tabled = Self.lookup(for: place, Self.tableEntry)
            ?? TableEntry(radius: Self.pointRadius, kind: .point)
        radius = tabled.radius
        kind = tabled.kind
    }

    /// Meters from `fix` to the nearest point of the venue; zero inside it.
    /// Nil when the place has no coordinate at all.
    func effectiveDistance(from fix: PlaceLocation, to place: Place) -> Double? {
        guard let location = place.location else { return nil }
        return max(0, GeoDistance.meters(from: fix, to: location) - radius)
    }
}
