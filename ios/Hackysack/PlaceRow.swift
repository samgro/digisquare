//
//  PlaceRow.swift
//  Hackysack
//

import CoreLocation
import SwiftUI

struct PlaceRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let place: Place
    let userLocation: CLLocation?
    /// How many times the user has checked in here before; zero hides the line.
    var visitCount: Int = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                if place.isPrivate {
                    Image(systemName: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Private place")
                }
            }

            if let subtitle = place.subtitle(from: userLocation) {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                    .truncationMode(.tail)
            }

            if let visitLine {
                Label(visitLine, systemImage: Glyphs.visitedBefore)
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
                    .lineLimit(1)
            }
        }
        // Together these make the whole row width tappable, including the gap
        // between the two lines. Without the frame the VStack hugs its text.
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
    }

    /// The API coerces a missing `displayName` to an empty string, which would
    /// otherwise render as a blank headline.
    private var title: String {
        let trimmed = place.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Unnamed Place" : trimmed
    }

    private var visitLine: String? {
        if visitCount < 1 {
            return nil
        }
        if visitCount == 1 {
            return "You've checked in here before"
        }
        return "You've checked in \(visitCount) times"
    }
}

// MARK: - Previews

private let previewUserLocation = CLLocation(latitude: 37.7749, longitude: -122.4194)

private let previewPlaces: [Place] = [
    // Distance + address.
    Place(
        id: "1",
        name: "Blue Bottle Coffee",
        address: "450 10th St, San Francisco, CA 94103, US",
        street: "450 10th St",
        locality: "San Francisco",
        location: PlaceLocation(latitude: 37.7749, longitude: -122.4196),
        types: ["coffee_shop", "cafe"],
        primaryType: "coffee_shop",
        checkinCount: 120
    ),
    // Long name — exercises the two-line title.
    Place(
        id: "2",
        name: "Philz Coffee – Mint Plaza at Fifth and Mission Street",
        address: "16 Mint Plaza, San Francisco, CA 94103, US",
        street: "16 Mint Plaza",
        locality: "San Francisco",
        location: PlaceLocation(latitude: 37.7719, longitude: -122.4145),
        types: ["coffee_shop"],
        primaryType: "coffee_shop",
        checkinCount: 89
    ),
    // No coordinate — address only, no leading separator.
    Place(
        id: "3",
        source: .google,
        name: "Tartine Manufactory",
        address: "595 Alabama St, San Francisco, CA 94110, US",
        street: "595 Alabama St",
        locality: "San Francisco",
        location: nil,
        types: ["bakery"],
        primaryType: "bakery"
    ),
    // No address — distance only.
    Place(
        id: "4",
        name: "Golden Gate Park",
        location: PlaceLocation(latitude: 37.7694, longitude: -122.4862),
        types: ["park"],
        primaryType: "park"
    ),
    // A private venue the user added, with a street line and no city.
    Place(
        id: "5",
        source: .user,
        name: "Pier 39",
        address: "Pier 39",
        street: "Pier 39",
        location: PlaceLocation(latitude: 37.8087, longitude: -122.4098),
        types: ["attractions_and_activities"],
        primaryType: "attractions_and_activities",
        isPrivate: true
    ),
    // Neither distance nor address — subtitle is omitted entirely.
    Place(
        id: "6",
        name: "Mystery Spot",
        location: nil
    ),
    // Empty name from the server — exercises the title fallback.
    Place(
        id: "7",
        name: "",
        address: "1 Ferry Building, San Francisco, CA 94111, US",
        street: "1 Ferry Building",
        locality: "San Francisco",
        location: PlaceLocation(latitude: 37.7955, longitude: -122.3937)
    ),
]

#Preview("Rows") {
    List(previewPlaces) { place in
        Button {} label: {
            PlaceRow(place: place, userLocation: previewUserLocation)
        }
        .buttonStyle(.plain)
    }
    .listStyle(.plain)
}

#Preview("Rows – With History") {
    List {
        PlaceRow(place: previewPlaces[0], userLocation: previewUserLocation, visitCount: 12)
        PlaceRow(place: previewPlaces[1], userLocation: previewUserLocation, visitCount: 1)
        PlaceRow(place: previewPlaces[2], userLocation: previewUserLocation)
    }
    .listStyle(.plain)
}

#Preview("Rows – No User Location") {
    List(previewPlaces) { place in
        PlaceRow(place: place, userLocation: nil)
    }
    .listStyle(.plain)
}

#Preview("Rows – Accessibility XL") {
    List(previewPlaces) { place in
        PlaceRow(place: place, userLocation: previewUserLocation)
    }
    .listStyle(.plain)
    .dynamicTypeSize(.accessibility3)
}

#Preview("Rows – Dark") {
    List(previewPlaces) { place in
        PlaceRow(place: place, userLocation: previewUserLocation)
    }
    .listStyle(.plain)
    .preferredColorScheme(.dark)
}
