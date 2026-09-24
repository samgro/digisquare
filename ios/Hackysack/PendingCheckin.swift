//
//  PendingCheckin.swift
//  Hackysack
//

import Foundation

/// A checkin the app suggested from a detected visit that the user has not yet
/// accepted, corrected, or removed. Lives only on the device: nothing reaches
/// the API until the user decides.
struct PendingCheckin: Codable, Identifiable, Equatable {
    let id: UUID
    var visit: VisitRecord
    /// Nearby places, most likely first. The first one is the initial guess.
    var candidatePlaces: [Place]
    var selectedPlaceId: String
    var visibility: CheckinVisibility
    let createdAt: Date
    /// Visits that turned out to be the same stay (the user stepped out and came
    /// back within a couple of hours). Deliveries for them update this suggestion.
    var continuationVisitIds: [UUID] = []

    init(
        id: UUID = UUID(),
        visit: VisitRecord,
        candidatePlaces: [Place],
        selectedPlaceId: String? = nil,
        visibility: CheckinVisibility = .friends,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.visit = visit
        self.candidatePlaces = candidatePlaces
        self.selectedPlaceId = selectedPlaceId ?? candidatePlaces.first?.id ?? ""
        self.visibility = visibility
        self.createdAt = createdAt
    }

    var selectedPlace: Place? {
        candidatePlaces.first { $0.id == selectedPlaceId }
    }

    /// The other candidates, offered when the user rejects the initial guess.
    var alternativePlaces: [Place] {
        candidatePlaces.filter { $0.id != selectedPlaceId }
    }
}

extension PendingCheckin {
    static func preview(
        visibility: CheckinVisibility = .friends,
        arrivedMinutesAgo: Double = 95,
        isOngoing: Bool = false
    ) -> PendingCheckin {
        let arrival = Date().addingTimeInterval(-arrivedMinutesAgo * 60)
        let visit = VisitRecord(
            coordinate: GeoCoordinate(latitude: 37.7764, longitude: -122.4231),
            horizontalAccuracy: 45,
            arrivalDate: arrival,
            departureDate: isOngoing ? nil : Date().addingTimeInterval(-5 * 60)
        )
        let alternative = Place(
            id: "ChIJalternative",
            name: "Linden Street Bakery",
            address: "320 Linden St, San Francisco",
            location: PlaceLocation(latitude: 37.7765, longitude: -122.4229),
            types: ["bakery"],
            primaryType: "bakery",
            rating: 4.2,
            userRatingCount: 340
        )
        return PendingCheckin(
            visit: visit,
            candidatePlaces: [Place.preview, alternative],
            visibility: visibility,
            createdAt: arrival
        )
    }
}
