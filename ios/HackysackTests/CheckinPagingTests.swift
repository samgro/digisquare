//
//  CheckinPagingTests.swift
//  HackysackTests
//

import Foundation
import Testing
@testable import Hackysack

@Suite("Checkin paging")
struct CheckinPagingTests {
    private static let newest = Date(timeIntervalSince1970: 1_758_000_000)

    /// `count` checkins, newest first, one minute apart, the first of them
    /// `minutesBack` minutes before a fixed moment, so two calls with the same
    /// arguments build the same checkins.
    private func page(count: Int, startingMinutesBack minutesBack: Int = 0) -> [Checkin] {
        (0..<count).map { index in
            let minutes = minutesBack + index
            let createdAt = Self.newest.addingTimeInterval(-Double(minutes) * 60)
            return Checkin(
                id: "checkin-\(minutes)",
                userId: "user",
                placeId: "place",
                placeName: "Somewhere",
                placeAddress: nil,
                placeLocality: nil,
                placeRegion: nil,
                placeCountry: nil,
                placePrimaryType: nil,
                placeTypes: nil,
                placeCategoryName: nil,
                location: nil,
                message: nil,
                visibility: .friends,
                source: .manual,
                timeZoneOffsetMinutes: nil,
                createdAt: createdAt,
                updatedAt: createdAt
            )
        }
    }

    @Test func aShortFirstPageIsTheWholeHistory() {
        let firstPage = page(count: 3)
        let merged = CheckinPaging.mergeFirstPage(
            firstPage,
            into: page(count: 10, startingMinutesBack: 100),
            loadedCursor: Self.newest,
            checkin: { $0 }
        )

        #expect(merged.items.map(\.id) == firstPage.map(\.id))
        #expect(merged.nextCursor == nil)
    }

    @Test func aFullFirstPageKeepsOlderPagesAlreadyLoaded() {
        let older = page(count: 20, startingMinutesBack: 200)
        let loaded = page(count: CheckinPaging.pageSize) + older
        let refreshed = page(count: CheckinPaging.pageSize)
        let olderCursor = older.last?.createdAt

        let merged = CheckinPaging.mergeFirstPage(refreshed, into: loaded, loadedCursor: olderCursor, checkin: { $0 })

        #expect(merged.items.count == CheckinPaging.pageSize + older.count)
        #expect(merged.items.suffix(older.count).map(\.id) == older.map(\.id))
        #expect(merged.nextCursor == olderCursor)
    }

    @Test func aRefreshedFirstPageNeverRepeatsACheckinItAlreadyHolds() {
        // A new checkin at the top pushes the old page's last row past the
        // refreshed page's end, so it is older than the cursor but not new.
        let loaded = page(count: CheckinPaging.pageSize, startingMinutesBack: 1)
        let refreshed = page(count: CheckinPaging.pageSize)

        let merged = CheckinPaging.mergeFirstPage(refreshed, into: loaded, loadedCursor: nil, checkin: { $0 })

        #expect(Set(merged.items.map(\.id)).count == merged.items.count)
        #expect(merged.items.count == CheckinPaging.pageSize + 1)
    }

    @Test func aFullFirstPageWithNothingOlderContinuesFromItsEnd() {
        let refreshed = page(count: CheckinPaging.pageSize)

        let merged = CheckinPaging.mergeFirstPage(refreshed, into: [], loadedCursor: nil, checkin: { $0 })

        #expect(merged.nextCursor == refreshed.last?.createdAt)
    }

    @Test func appendingSkipsCheckinsAlreadyLoaded() {
        let loaded = page(count: 3)
        let nextPage = [loaded[2]] + page(count: 2, startingMinutesBack: 10)

        let appended = CheckinPaging.appendPage(nextPage, to: loaded, checkin: { $0 })

        #expect(appended.count == 5)
        #expect(Set(appended.map(\.id)).count == 5)
    }

    @Test func aShortPageHasNoNextCursor() {
        #expect(CheckinPaging.nextCursor(after: page(count: 5), checkin: { $0 }) == nil)
        #expect(CheckinPaging.nextCursor(after: [], checkin: { $0 }) == nil)
    }
}
