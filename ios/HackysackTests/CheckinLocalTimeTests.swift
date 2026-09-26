//
//  CheckinLocalTimeTests.swift
//  HackysackTests
//

import Foundation
import Testing
@testable import Hackysack

@Suite("Checkin local time")
struct CheckinLocalTimeTests {
    /// 03:00 UTC on 2 Sep: still 1 Sep in California, already 2 Sep in Tokyo.
    private let createdAt = Date(timeIntervalSince1970: 1_756_782_000)

    private func checkin(offsetMinutes: Int?) -> Checkin {
        Checkin(
            id: "checkin",
            userId: "user",
            placeId: "place",
            placeName: "Somewhere",
            placeAddress: nil,
            placeLocality: nil,
            placePrimaryType: nil,
            placeTypes: nil,
            placeCategoryName: nil,
            location: nil,
            message: nil,
            visibility: .friends,
            source: .swarm,
            timeZoneOffsetMinutes: offsetMinutes,
            createdAt: createdAt,
            updatedAt: createdAt
        )
    }

    @Test func groupsByTheDayWhereTheCheckinHappened() throws {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = try #require(TimeZone(identifier: "UTC"))

        let california = checkin(offsetMinutes: -7 * 60).localDay(in: utc)
        let tokyo = checkin(offsetMinutes: 9 * 60).localDay(in: utc)

        #expect(utc.component(.day, from: california) == 1)
        #expect(utc.component(.day, from: tokyo) == 2)
    }

    @Test func fallsBackToTheDeviceZoneWhenTheOffsetIsUnknown() {
        #expect(checkin(offsetMinutes: nil).timeZone == .current)
    }

    @Test func formatsTheTimeInTheCheckinsZone() {
        let california = checkin(offsetMinutes: -7 * 60)
        let tokyo = checkin(offsetMinutes: 9 * 60)

        #expect(california.formattedCheckinTime != tokyo.formattedCheckinTime)
        #expect(california.formattedCheckinTime.contains("8:00"))
        #expect(tokyo.formattedCheckinTime.contains("12:00"))
    }

    @Test func prefersTheSourcesOwnCategoryLabel() {
        let checkin = Checkin.preview(primaryType: "asian_restaurant", source: .swarm, categoryName: "Hotpot Restaurant")
        #expect(checkin.categoryName == "Hotpot Restaurant")
        #expect(Checkin.preview(primaryType: "coffee_shop").categoryName == "Coffee Shop")
    }
}
