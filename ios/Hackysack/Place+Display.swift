//
//  Place+Display.swift
//  Hackysack
//

import CoreLocation
import Foundation

extension Place {
    /// The place's coordinate as a `CLLocation`, or `nil` when the server omitted it.
    private var coordinateLocation: CLLocation? {
        guard let location else { return nil }
        return CLLocation(latitude: location.latitude, longitude: location.longitude)
    }

    /// Just the street line: "450 10th St". Returns `nil` when the place has
    /// none, rather than showing the city where a street belongs.
    var streetLine: String? {
        guard let street else { return nil }
        let trimmed = street.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Straight-line distance from the user, formatted for the current locale:
    /// "5 ft" / "350 ft" / "0.62 mi" in the US, "5 yd" / "0.62 mi" in the UK,
    /// "5 m" / "1,5 km" in metric locales.
    ///
    /// Measured to the venue's grounds when it has them (so an airport reads
    /// "0 ft" from a gate, not "0.9 mi" to its pin), else to its pin. Falls
    /// back to the distance the server measured when the user's location is
    /// unknown. Returns `nil` when neither is available. The format style
    /// already defaults to `Locale.autoupdatingCurrent`, so it tracks
    /// Settings changes and is cheap enough not to need caching.
    func formattedDistance(from userLocation: CLLocation?) -> String? {
        guard let distanceInMeters = distanceInMeters(from: userLocation) else { return nil }
        let distance = Measurement<UnitLength>(value: distanceInMeters, unit: .meters)
        return distance.formatted(.measurement(width: .abbreviated, usage: .road))
    }

    private func distanceInMeters(from userLocation: CLLocation?) -> Double? {
        guard let userLocation else { return distanceMeters }
        let fix = PlaceLocation(
            latitude: userLocation.coordinate.latitude,
            longitude: userLocation.coordinate.longitude
        )
        if let extent, extent.rings.contains(where: { !$0.isEmpty }) {
            return extent.contains(fix) ? 0 : extent.distanceToEdge(from: fix)
        }
        guard let coordinateLocation else { return distanceMeters }
        return userLocation.distance(from: coordinateLocation)
    }

    /// "60 ft · 450 10th St", or whichever of the two parts is available, or `nil`
    /// when neither is. Assembling from a compacted array means a missing distance
    /// never leaves a dangling separator.
    func subtitle(from userLocation: CLLocation?) -> String? {
        let parts = [formattedDistance(from: userLocation), streetLine].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
