//
//  CheckinHistorySyncTests.swift
//  HackysackTests
//

import Foundation
import SwiftData
import Testing
@testable import Hackysack

@MainActor
@Suite("Checkin history store")
struct CheckinHistorySyncTests {
    private static let checkinId = "880e8400-e29b-41d4-a716-446655440000"
    private static let createdAt = Date(timeIntervalSince1970: 1_790_000_000)

    private func checkin(updatedMinutesLater minutes: Double, likeCount: Int) -> Checkin {
        Checkin(
            id: Self.checkinId,
            userId: "user",
            placeId: "place",
            placeName: "Blue Bottle Coffee",
            placeAddress: nil,
            placeLocality: "San Francisco",
            placeRegion: "US-CA",
            placeCountry: "US",
            placePrimaryType: "coffee_shop",
            placeTypes: nil,
            placeCategoryName: nil,
            location: nil,
            message: nil,
            visibility: .friends,
            source: .manual,
            timeZoneOffsetMinutes: nil,
            likeCount: likeCount,
            createdAt: Self.createdAt,
            updatedAt: Self.createdAt.addingTimeInterval(minutes * 60)
        )
    }

    private func storedLikeCount(in historySync: CheckinHistorySync) throws -> Int? {
        try historySync.container.mainContext.fetch(FetchDescriptor<CheckinRecord>()).first?.likeCount
    }

    @Test func anOlderCopyDoesNotOverwriteANewerOne() throws {
        let historySync = CheckinHistorySync.preview(checkins: [checkin(updatedMinutesLater: 10, likeCount: 3)])

        historySync.store(checkin(updatedMinutesLater: 5, likeCount: 1))

        #expect(try storedLikeCount(in: historySync) == 3)
    }

    @Test func aCopyWithTheSameTimestampStillApplies() throws {
        // A like made on this device changes the counts but not updatedAt.
        let historySync = CheckinHistorySync.preview(checkins: [checkin(updatedMinutesLater: 10, likeCount: 3)])

        historySync.store(checkin(updatedMinutesLater: 10, likeCount: 4))

        #expect(try storedLikeCount(in: historySync) == 4)
    }

    @Test func aNewerCopyApplies() throws {
        let historySync = CheckinHistorySync.preview(checkins: [checkin(updatedMinutesLater: 10, likeCount: 3)])

        historySync.store(checkin(updatedMinutesLater: 15, likeCount: 5))

        #expect(try storedLikeCount(in: historySync) == 5)
    }
}
