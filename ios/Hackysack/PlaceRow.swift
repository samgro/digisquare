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
            Text(title)
                .font(.headline)
                .foregroundStyle(.primary)
                .lineLimit(2)

            if let subtitle = place.subtitle(from: userLocation) {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                    .truncationMode(.tail)
            }

            if let visitLine {
                Label(visitLine, systemImage: "checkmark.circle")
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
        address: "450 10th St, San Francisco, CA 94103, USA",
        location: PlaceLocation(latitude: 37.7749, longitude: -122.4196),
        types: ["cafe"],
        primaryType: "coffee_shop",
        rating: 4.5,
        userRatingCount: 1203
    ),
    // Long name — exercises the two-line title.
    Place(
        id: "2",
        name: "Philz Coffee – Mint Plaza at Fifth and Mission Street",
        address: "16 Mint Plaza, San Francisco, CA 94103, USA",
        location: PlaceLocation(latitude: 37.7719, longitude: -122.4145),
        types: ["cafe"],
        primaryType: "coffee_shop",
        rating: 4.4,
        userRatingCount: 890
    ),
    // No coordinate — address only, no leading separator.
    Place(
        id: "3",
        name: "Tartine Manufactory",
        address: "595 Alabama St, San Francisco, CA 94110, USA",
        location: nil,
        types: ["bakery"],
        primaryType: "bakery",
        rating: nil,
        userRatingCount: nil
    ),
    // No address — distance only.
    Place(
        id: "4",
        name: "Golden Gate Park",
        address: nil,
        location: PlaceLocation(latitude: 37.7694, longitude: -122.4862),
        types: ["park"],
        primaryType: "park",
        rating: nil,
        userRatingCount: nil
    ),
    // Address with no comma.
    Place(
        id: "5",
        name: "Pier 39",
        address: "Pier 39",
        location: PlaceLocation(latitude: 37.8087, longitude: -122.4098),
        types: ["tourist_attraction"],
        primaryType: "tourist_attraction",
        rating: nil,
        userRatingCount: nil
    ),
    // Neither distance nor address — subtitle is omitted entirely.
    Place(
        id: "6",
        name: "Mystery Spot",
        address: nil,
        location: nil,
        types: [],
        primaryType: nil,
        rating: nil,
        userRatingCount: nil
    ),
    // Empty name from the server — exercises the title fallback.
    Place(
        id: "7",
        name: "",
        address: "1 Ferry Building, San Francisco, CA 94111, USA",
        location: PlaceLocation(latitude: 37.7955, longitude: -122.3937),
        types: [],
        primaryType: nil,
        rating: nil,
        userRatingCount: nil
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
