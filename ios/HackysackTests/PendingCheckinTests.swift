//
//  PendingCheckinTests.swift
//  HackysackTests
//

import Foundation
import Testing
@testable import Hackysack

@Suite("Suggestion deduplication")
struct PendingCheckinTests {
    private static let visitCoordinate = GeoCoordinate(latitude: 37.7764, longitude: -122.4231)
    private static let arrival = Date(timeIntervalSince1970: 1_790_000_000)
    private static let departure = arrival.addingTimeInterval(2 * 60 * 60)

    /// About 167 m north of the visit.
    private static let nearbyLocation = PlaceLocation(latitude: 37.7779, longitude: -122.4231)
    /// About 1.1 km north of the visit.
    private static let distantLocation = PlaceLocation(latitude: 37.7864, longitude: -122.4231)

    private func suggestion(horizontalAccuracy: Double = 45, isOngoing: Bool = false) -> PendingCheckin {
        PendingCheckin(
            visit: VisitRecord(
                coordinate: Self.visitCoordinate,
                horizontalAccuracy: horizontalAccuracy,
                arrivalDate: Self.arrival,
                departureDate: isOngoing ? nil : Self.departure
            ),
            candidatePlaces: [Place.preview]
        )
    }

    private func checkin(at location: PlaceLocation?, hoursFromArrival: Double) -> Checkin {
        let createdAt = Self.arrival.addingTimeInterval(hoursFromArrival * 60 * 60)
        return Checkin(
            id: UUID().uuidString,
            userId: "user",
            placeId: "place",
            placeName: "Somewhere",
            placeAddress: nil,
            placeLocality: nil,
            placePrimaryType: nil,
            placeTypes: nil,
            placeCategoryName: nil,
            location: location,
            message: nil,
            visibility: .friends,
            source: .manual,
            timeZoneOffsetMinutes: nil,
            createdAt: createdAt,
            updatedAt: createdAt
        )
    }

    private var afterTheStay: Date { Self.departure.addingTimeInterval(6 * 60 * 60) }

    @Test func aCheckinAnywhereDuringTheStayCoversIt() {
        let checkins = [checkin(at: Self.distantLocation, hoursFromArrival: 1)]
        #expect(suggestion().isCovered(by: checkins, now: afterTheStay))
    }

    @Test func anOngoingStayRunsUpToNow() {
        let checkins = [checkin(at: Self.distantLocation, hoursFromArrival: 3)]
        let now = Self.arrival.addingTimeInterval(4 * 60 * 60)
        #expect(suggestion(isOngoing: true).isCovered(by: checkins, now: now))
    }

    @Test func aCheckinAtTheSameSpotJustBeforeArrivingCoversIt() {
        let checkins = [checkin(at: Self.nearbyLocation, hoursFromArrival: -0.25)]
        #expect(suggestion().isCovered(by: checkins, now: afterTheStay))
    }

    @Test func aCheckinAtTheSameSpotJustAfterLeavingCoversIt() {
        let checkins = [checkin(at: Self.nearbyLocation, hoursFromArrival: 2.25)]
        #expect(suggestion().isCovered(by: checkins, now: afterTheStay))
    }

    @Test func checkinsElsewhereBeforeAndAfterDoNotCoverIt() {
        let checkins = [
            checkin(at: Self.distantLocation, hoursFromArrival: -1),
            checkin(at: Self.distantLocation, hoursFromArrival: 3),
        ]
        #expect(!suggestion().isCovered(by: checkins, now: afterTheStay))
    }

    @Test func onlyTheAdjacentCheckinsAreCompared() {
        let checkins = [
            checkin(at: Self.nearbyLocation, hoursFromArrival: -5),
            checkin(at: Self.distantLocation, hoursFromArrival: -1),
            checkin(at: Self.distantLocation, hoursFromArrival: 3),
            checkin(at: Self.nearbyLocation, hoursFromArrival: 8),
        ]
        #expect(!suggestion().isCovered(by: checkins, now: afterTheStay))
    }

    @Test func aCheckinAtTheSameSpotMoreThanTwelveHoursAwayDoesNotCoverIt() {
        // The stay runs from hour 0 to hour 2.
        #expect(suggestion().isCovered(by: [checkin(at: Self.nearbyLocation, hoursFromArrival: -11)], now: afterTheStay))
        #expect(!suggestion().isCovered(by: [checkin(at: Self.nearbyLocation, hoursFromArrival: -13)], now: afterTheStay))
        #expect(suggestion().isCovered(by: [checkin(at: Self.nearbyLocation, hoursFromArrival: 13)], now: afterTheStay))
        #expect(!suggestion().isCovered(by: [checkin(at: Self.nearbyLocation, hoursFromArrival: 15)], now: afterTheStay))
    }

    @Test func theVisitsAccuracyWidensTheSameSpotRadius() {
        let checkins = [checkin(at: Self.nearbyLocation, hoursFromArrival: -0.25)]
        #expect(!suggestion(horizontalAccuracy: 10).isCovered(by: checkins, now: afterTheStay))
        #expect(suggestion(horizontalAccuracy: 45).isCovered(by: checkins, now: afterTheStay))
    }

    @Test func anAdjacentCheckinWithoutALocationDoesNotCoverIt() {
        let checkins = [checkin(at: nil, hoursFromArrival: -0.25)]
        #expect(!suggestion().isCovered(by: checkins, now: afterTheStay))
    }

    @MainActor
    @Test func theTimelineHidesASuggestionOnceTheUserChecksInDuringTheStay() {
        let store = CheckinStore.inMemory()
        store.add(suggestion: .preview(isOngoing: true))
        #expect(store.timelineEntries.contains { $0.syncStatus == .suggested })

        store.submit(place: .preview, message: nil)

        #expect(!store.timelineEntries.contains { $0.syncStatus == .suggested })
        #expect(store.suggestions.count == 1)
    }
}
