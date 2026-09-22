//
//  PreviewData.swift
//  Hackysack
//

import Foundation

extension Place {
    static let preview = Place(
        id: "ChIJpreview",
        name: "Blue Bottle Coffee",
        address: "315 Linden St, San Francisco",
        location: PlaceLocation(latitude: 37.7764, longitude: -122.4231),
        types: ["cafe", "coffee_shop"],
        primaryType: "cafe",
        rating: 4.5,
        userRatingCount: 1200
    )
}

extension Checkin {
    static func preview(
        id: String = UUID().uuidString,
        userId: String = "00000000-0000-0000-0000-00000000da7a",
        message: String? = "Best cortado in the Mission",
        primaryType: String? = "cafe",
        minutesAgo: Double = 2
    ) -> Checkin {
        let createdAt = Date().addingTimeInterval(-minutesAgo * 60)
        return Checkin(
            id: id,
            userId: userId,
            googlePlaceId: Place.preview.id,
            placeName: Place.preview.name,
            placeAddress: Place.preview.address,
            placePrimaryType: primaryType,
            placeTypes: Place.preview.types,
            location: Place.preview.location,
            message: message,
            createdAt: createdAt,
            updatedAt: createdAt
        )
    }
}
