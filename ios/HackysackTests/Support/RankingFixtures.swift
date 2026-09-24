//
//  RankingFixtures.swift
//  HackysackTests
//

import Foundation
@testable import Hackysack

/// One file in `fixtures/ranking/`: recorded Google data for a real spot the
/// user might be standing in, the exact `/places` output for it, sample
/// checkin histories, and the outcomes each combination should produce.
///
/// The files are shared with the API's tests and written by
/// `npm run fixtures:record` in `api/`; see `api/scripts/ranking-scenarios.ts`.
nonisolated struct RankingFixture: Decodable, Sendable {
    struct Fix: Decodable, Sendable {
        let latitude: Double
        let longitude: Double
        let horizontalAccuracy: Double
    }

    struct Expectation: Decodable, Sendable {
        /// Key of the place that must rank first, when the case pins that down.
        let top: String?
        /// Absent means the case says nothing about the suggestion.
        let suggested: SuggestionExpectation?
        /// Pairs of keys [above, below] that must rank in that order.
        let rankedAbove: [[String]]

        private enum CodingKeys: String, CodingKey {
            case top, suggested, rankedAbove
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            top = try container.decodeIfPresent(String.self, forKey: .top)
            rankedAbove = try container.decodeIfPresent([[String]].self, forKey: .rankedAbove) ?? []
            if container.contains(.suggested) {
                if try container.decodeNil(forKey: .suggested) {
                    suggested = .noSuggestion
                } else {
                    suggested = .place(try container.decode(String.self, forKey: .suggested))
                }
            } else {
                suggested = nil
            }
        }
    }

    enum SuggestionExpectation: Equatable, Sendable {
        /// `"suggested": null` in the file: the picker must show the list.
        case noSuggestion
        /// `"suggested": "<key>"`: the picker must jump to that place.
        case place(String)
    }

    struct Case: Decodable, Sendable {
        let name: String
        let now: Date
        let horizontalAccuracy: Double
        let fixAgeSeconds: Double
        let history: String
        let expect: Expectation
    }

    let name: String
    let description: String
    let recordedAt: Date?
    let timeZone: String
    let fix: Fix
    let places: [Place]
    let placeKeys: [String: String]
    let histories: [String: [CheckinHistoryEntry]]
    let cases: [Case]

    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZone) ?? .current
        return calendar
    }

    func placeIdentifier(forKey key: String) -> String? {
        placeKeys[key]
    }

    func placeName(forIdentifier identifier: String) -> String {
        places.first { $0.id == identifier }?.name ?? identifier
    }
}

nonisolated enum RankingFixtures {
    /// `fixtures/ranking/` at the repo root, found relative to this source
    /// file so the test needs no bundle resources and reads the very same
    /// files the API's tests do.
    static let directory: URL = URL(filePath: #filePath)
        .deletingLastPathComponent() // Support
        .deletingLastPathComponent() // HackysackTests
        .deletingLastPathComponent() // ios
        .deletingLastPathComponent() // repository root
        .appending(path: "fixtures/ranking")

    static func names() throws -> [String] {
        try FileManager.default
            .contentsOfDirectory(atPath: directory.path())
            .filter { $0.hasSuffix(".json") }
            .map { String($0.dropLast(".json".count)) }
            .sorted()
    }

    static func load(_ name: String) throws -> RankingFixture {
        let data = try Data(contentsOf: directory.appending(path: "\(name).json"))
        return try makeDecoder().decode(RankingFixture.self, from: data)
    }

    /// Mirrors APIClient's date handling: the recorder writes dates with
    /// `toISOString()` (always fractional seconds) while the scenario
    /// definitions use plain offsets like `2026-09-22T10:15:00-07:00`.
    /// Built fresh per call so it is usable from any isolation.
    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            let withFractionalSeconds = ISO8601DateFormatter()
            withFractionalSeconds.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = withFractionalSeconds.date(from: text) {
                return date
            }
            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            if let date = plain.date(from: text) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unrecognized date format: \(text)"
            )
        }
        return decoder
    }
}
