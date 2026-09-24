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
nonisolated struct PlaceFootprint: Sendable {
    /// Half the venue's extent in meters: for a rectangle, half its shorter side.
    let radius: Double
    let kind: PlaceFootprintClass
    /// Google's bounding box when it is large enough to be informative. Nil
    /// means the venue is modeled as a disc of `radius` around its pin.
    let rectangle: PlaceViewport?

    /// Google returns a default box roughly 250 m across for point venues, so a
    /// box only counts as the venue's real extent when its shorter half-side
    /// clears that comfortably.
    static let informativeViewportHalfSide = 200.0

    /// Storefront radius. Generous on purpose: Google pins are often a shop
    /// width off, and the user is somewhere inside the shop, not at the pin.
    static let pointRadius = 25.0

    private struct TableEntry {
        let radius: Double
        let kind: PlaceFootprintClass
    }

    private static let table: [String: TableEntry] = [
        "airport": TableEntry(radius: 1500, kind: .destination),
        "university": TableEntry(radius: 600, kind: .destination),
        "amusement_park": TableEntry(radius: 600, kind: .destination),
        "zoo": TableEntry(radius: 600, kind: .destination),
        "ski_resort": TableEntry(radius: 600, kind: .destination),
        "golf_course": TableEntry(radius: 600, kind: .destination),
        "national_park": TableEntry(radius: 600, kind: .destination),
        "state_park": TableEntry(radius: 600, kind: .destination),
        "stadium": TableEntry(radius: 300, kind: .destination),
        "park": TableEntry(radius: 150, kind: .container),
        "shopping_mall": TableEntry(radius: 150, kind: .container),
        "train_station": TableEntry(radius: 150, kind: .container),
        "transit_station": TableEntry(radius: 150, kind: .container),
        "hospital": TableEntry(radius: 150, kind: .container),
        "sports_complex": TableEntry(radius: 150, kind: .container),
        "convention_center": TableEntry(radius: 150, kind: .container),
        "campground": TableEntry(radius: 150, kind: .container),
        "marina": TableEntry(radius: 150, kind: .container),
        "botanical_garden": TableEntry(radius: 150, kind: .container),
        // The building is the checkin; the listings inside are its offices.
        "city_hall": TableEntry(radius: 60, kind: .destination),
        "courthouse": TableEntry(radius: 60, kind: .destination),
        "hotel": TableEntry(radius: 60, kind: .container),
        "resort_hotel": TableEntry(radius: 60, kind: .container),
        "museum": TableEntry(radius: 60, kind: .container),
        "school": TableEntry(radius: 60, kind: .container),
        "local_government_office": TableEntry(radius: 60, kind: .container),
        "garden": TableEntry(radius: 60, kind: .container),
        "plaza": TableEntry(radius: 60, kind: .container),
    ]

    /// Log-prior adjustments for place types that a nearest-first search
    /// surfaces at 5 m but almost nobody means to check in at. Penalties only,
    /// so the places stay in the list for the rare time they are wanted.
    private static let typePriors: [String: Double] = [
        "parking": -1.5,
        "parking_lot": -1.5,
        "parking_garage": -1.5,
        "public_bathroom": -1.5,
        "electric_vehicle_charging_station": -1.0,
        // Offices listed inside a building someone would actually check in at:
        // a town hall's departments, the startups registered at a coworking
        // address. Recorded fixtures have a dozen of these within 25 m.
        "government_office": -1.0,
        "local_government_office": -1.0,
        "corporate_office": -1.0,
        "association_or_organization": -1.0,
        "general_contractor": -1.0,
        "consultant": -1.0,
        "finance": -1.0,
        "service": -1.0,
        "atm": -1.0,
        "bus_stop": -0.5,
        "storage": -0.5,
        "premise": -1.5,
        "street_address": -1.5,
        "subpremise": -1.5,
        "plus_code": -1.5,
        "route": -1.5,
    ]

    static func lookup<Value>(_ table: [String: Value], for place: Place) -> Value? {
        if let primaryType = place.primaryType, let value = table[primaryType] {
            return value
        }
        for type in place.types {
            if let value = table[type] {
                return value
            }
        }
        return nil
    }

    /// Judged on the primary type alone when there is one: a town hall is
    /// also tagged `local_government_office`, and that must not count
    /// against it.
    static func typePrior(for place: Place) -> Double {
        if let primaryType = place.primaryType {
            return typePriors[primaryType] ?? 0
        }
        return lookup(typePriors, for: place) ?? 0
    }

    init(for place: Place) {
        let tabled = Self.lookup(Self.table, for: place)
            ?? TableEntry(radius: Self.pointRadius, kind: .point)

        if let viewport = place.viewport {
            let halfNorth = (viewport.high.latitude - viewport.low.latitude) / 2 * GeoDistance.metersPerDegreeLatitude
            let centerLatitude = (viewport.high.latitude + viewport.low.latitude) / 2
            let halfEast = (viewport.high.longitude - viewport.low.longitude) / 2
                * GeoDistance.metersPerDegreeLongitude(atLatitude: centerLatitude)
            let shorterHalfSide = min(halfNorth, halfEast)
            if shorterHalfSide > Self.informativeViewportHalfSide {
                radius = shorterHalfSide
                // A big box around something the table calls a storefront is
                // still a big venue; treat it as one whose parts matter.
                kind = tabled.kind == .point ? .container : tabled.kind
                rectangle = viewport
                return
            }
        }

        radius = tabled.radius
        // Google sends a real viewport for venues it knows are big, so a table
        // radius beyond its default box is a guess: without that confirmation
        // the venue does not get the smaller destination size price. This is
        // what keeps a regional airport 300 m away from beating the building
        // the user is standing in.
        if tabled.kind == .destination, tabled.radius > Self.informativeViewportHalfSide {
            kind = .container
        } else {
            kind = tabled.kind
        }
        rectangle = nil
    }

    /// Meters from `fix` to the nearest point of the venue; zero inside it.
    /// Nil when the place has no coordinate at all.
    func effectiveDistance(from fix: PlaceLocation, to place: Place) -> Double? {
        if let rectangle {
            let clamped = PlaceLocation(
                latitude: min(max(fix.latitude, rectangle.low.latitude), rectangle.high.latitude),
                longitude: min(max(fix.longitude, rectangle.low.longitude), rectangle.high.longitude)
            )
            return GeoDistance.meters(from: fix, to: clamped)
        }
        guard let location = place.location else { return nil }
        return max(0, GeoDistance.meters(from: fix, to: location) - radius)
    }
}
