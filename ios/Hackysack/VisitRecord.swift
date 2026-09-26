//
//  VisitRecord.swift
//  Hackysack
//

import Foundation

/// A latitude/longitude pair that doesn't depend on CoreLocation, so the visit
/// history and the home/work detector can be exercised in plain unit tests.
struct GeoCoordinate: Codable, Equatable, Hashable {
    let latitude: Double
    let longitude: Double

    private static let earthRadiusMeters = 6_371_000.0

    /// Straight-line distance in meters using the equirectangular approximation,
    /// which is accurate to well under 1% at the few-hundred-meter ranges the
    /// detector cares about and has no edge cases at the poles or antimeridian
    /// that matter here.
    func distance(to other: GeoCoordinate) -> Double {
        let degreesToRadians = Double.pi / 180
        let meanLatitude = (latitude + other.latitude) / 2 * degreesToRadians
        let deltaLatitude = (other.latitude - latitude) * degreesToRadians
        let deltaLongitude = (other.longitude - longitude) * degreesToRadians * cos(meanLatitude)
        return (deltaLatitude * deltaLatitude + deltaLongitude * deltaLongitude).squareRoot()
            * Self.earthRadiusMeters
    }
}

/// One stay at one location, as reported by Core Location's visit monitoring.
/// Core Location delivers the same visit twice (once on arrival with no
/// departure, once on departure), so `departureDate` is `nil` while the user
/// is still there.
struct VisitRecord: Codable, Identifiable, Equatable {
    let id: UUID
    var coordinate: GeoCoordinate
    var horizontalAccuracy: Double
    var arrivalDate: Date
    var departureDate: Date?
    /// When the app received the delivery. Used to backfill an unknown arrival.
    var receivedAt: Date
    /// False when Core Location did not know when the stay began (monitoring
    /// started mid-stay) and `arrivalDate` is the delivery time instead.
    var hasKnownArrival: Bool

    init(
        id: UUID = UUID(),
        coordinate: GeoCoordinate,
        horizontalAccuracy: Double,
        arrivalDate: Date,
        departureDate: Date? = nil,
        receivedAt: Date? = nil,
        hasKnownArrival: Bool = true
    ) {
        self.id = id
        self.coordinate = coordinate
        self.horizontalAccuracy = horizontalAccuracy
        self.arrivalDate = arrivalDate
        self.departureDate = departureDate
        self.receivedAt = receivedAt ?? departureDate ?? arrivalDate
        self.hasKnownArrival = hasKnownArrival
    }

    var isOngoing: Bool { departureDate == nil }

    /// How long the stay lasted, counting an ongoing stay up to `now`.
    func duration(until now: Date) -> TimeInterval {
        (departureDate ?? now).timeIntervalSince(arrivalDate)
    }
}

/// A confirmed checkin at a known place: either one the user made by hand or a
/// suggestion they accepted. The detector uses these to keep suggesting places
/// the user likes to check into even when they spend all day there.
struct VisitedPlaceEvent: Codable, Equatable {
    let coordinate: GeoCoordinate
    let placeId: String
    let date: Date
}

/// A suggestion the user removed rather than accepted or corrected. A removal
/// is the user telling us "don't suggest this stay", which the detector treats
/// as a stronger signal than any pattern it can infer.
struct RemovedSuggestion: Codable, Equatable {
    let coordinate: GeoCoordinate
    let date: Date
}
