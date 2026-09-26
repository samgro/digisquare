//
//  TimelineRowsTests.swift
//  HackysackTests
//

import Foundation
import Testing
@testable import Hackysack

@Suite("Timeline ordering")
struct TimelineRowsTests {
    @Test func suggestionsFallIntoTheDayTheUserWasThere() throws {
        let saved = TimelineEntry(id: UUID(), draft: nil, checkin: .preview(minutesAgo: 2), syncStatus: .saved)
        let yesterdaysSuggestion = try #require(TimelineEntry(suggestion: .preview(arrivedMinutesAgo: 26 * 60), userId: ""))

        let rows = timelineRows(for: [.entry(yesterdaysSuggestion), .entry(saved)])

        #expect(rows.count == 4)
        guard case .dayHeader = rows[0], case .item(.entry(let first)) = rows[1],
              case .dayHeader = rows[2], case .item(.entry(let second)) = rows[3] else {
            Issue.record("Unexpected row layout: \(rows.map(\.id))")
            return
        }
        #expect(first.id == saved.id)
        #expect(second.id == yesterdaysSuggestion.id)
        #expect(second.syncStatus == .suggested)
        #expect(second.checkin.source == .visit)
    }

    @Test func aSuggestionWithoutAUsablePlaceMakesNoRow() {
        let suggestion = PendingCheckin(visit: PendingCheckin.preview().visit, candidatePlaces: [])
        #expect(TimelineEntry(suggestion: suggestion, userId: "") == nil)
    }
}
