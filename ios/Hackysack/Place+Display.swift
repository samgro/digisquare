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
    /// Returns `nil` when either the user's location or the place's coordinate is
    /// unknown. The format style already defaults to `Locale.autoupdatingCurrent`,
    /// so it tracks Settings changes and is cheap enough not to need caching.
    func formattedDistance(from userLocation: CLLocation?) -> String? {
        guard let userLocation, let coordinateLocation else { return nil }
        let distanceInMeters = userLocation.distance(from: coordinateLocation)
        let distance = Measurement<UnitLength>(value: distanceInMeters, unit: .meters)
        return distance.formatted(.measurement(width: .abbreviated, usage: .road))
    }

    /// "60 ft · 450 10th St", or whichever of the two parts is available, or `nil`
    /// when neither is. Assembling from a compacted array means a missing distance
    /// never leaves a dangling separator.
    func subtitle(from userLocation: CLLocation?) -> String? {
        let parts = [formattedDistance(from: userLocation), streetLine].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
