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

    /// Slack beyond the visit's own accuracy within which the checkin just
    /// before or after the stay counts as having been made at the same spot.
    static let adjacentCheckinMarginMeters: Double = 150
    /// How long before arrival or after departure the checkin just before or
    /// after the stay can be and still count. An older one at the same spot is
    /// a separate trip there, not a duplicate of this one.
    static let adjacentCheckinWindow: TimeInterval = 12 * 60 * 60

    /// When a checkin has to have been made to count toward
    /// `isCovered(by:now:)`, so callers can narrow a long history first.
    func coverageWindow(now: Date) -> ClosedRange<Date> {
        let stayEnd = visit.departureDate ?? now
        let windowStart = visit.arrivalDate.addingTimeInterval(-Self.adjacentCheckinWindow)
        let windowEnd = stayEnd.addingTimeInterval(Self.adjacentCheckinWindow)
        return windowStart...max(windowStart, windowEnd)
    }

    /// Whether a real checkin already stands for this stay, which would make
    /// the suggestion a duplicate. That is the case when the user checked in
    /// anywhere while they were there, or when the checkin just before the
    /// stay or just after it is at the same spot and within 12 hours (they
    /// checked in on the way in, or on their way out). An ongoing stay runs
    /// up to `now`.
    func isCovered(by checkins: [Checkin], now: Date) -> Bool {
        let stayStart = visit.arrivalDate
        let stayEnd = visit.departureDate ?? now
        if checkins.contains(where: { $0.createdAt >= stayStart && $0.createdAt <= stayEnd }) {
            return true
        }

        let windowStart = stayStart.addingTimeInterval(-Self.adjacentCheckinWindow)
        let windowEnd = stayEnd.addingTimeInterval(Self.adjacentCheckinWindow)
        let previousCheckin = checkins
            .filter { $0.createdAt >= windowStart && $0.createdAt < stayStart }
            .max { $0.createdAt < $1.createdAt }
        let nextCheckin = checkins
            .filter { $0.createdAt > stayEnd && $0.createdAt <= windowEnd }
            .min { $0.createdAt < $1.createdAt }
        let sameSpotDistance = visit.horizontalAccuracy + Self.adjacentCheckinMarginMeters
        return [previousCheckin, nextCheckin].contains { checkin in
            guard let location = checkin?.location else { return false }
            let coordinate = GeoCoordinate(latitude: location.latitude, longitude: location.longitude)
            return visit.coordinate.distance(to: coordinate) <= sameSpotDistance
        }
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
            id: "b3d2e1f5-7c8e-4f4b-8d2a-2e3f4a5b6c7d",
            name: "Linden Street Bakery",
            address: "320 Linden St, San Francisco, CA 94102, US",
            location: PlaceLocation(latitude: 37.7765, longitude: -122.4229),
            types: ["bakery"],
            primaryType: "bakery"
        )
        return PendingCheckin(
            visit: visit,
            candidatePlaces: [Place.preview, alternative],
            visibility: visibility,
            createdAt: arrival
        )
    }
}
