//
//  PlaceRankerTests.swift
//  HackysackTests
//

import Foundation
import Testing
@testable import Hackysack

// MARK: - Recorded scenarios

/// One (scenario, case) pair from `fixtures/ranking/`, named so a failure
/// reads as "sfo-terminal-2 / tight fix, morning coffee regular".
nonisolated struct RankingScenarioCase: Sendable, CustomTestStringConvertible {
    let fixtureName: String
    let caseName: String

    var testDescription: String { "\(fixtureName) / \(caseName)" }

    /// Empty when the fixtures cannot be read; `fixturesExist` reports that
    /// loudly instead of this silently producing zero test cases.
    static var all: [RankingScenarioCase] {
        let names = (try? RankingFixtures.names()) ?? []
        return names.flatMap { fixtureName -> [RankingScenarioCase] in
            let cases = (try? RankingFixtures.load(fixtureName))?.cases ?? []
            return cases.map { RankingScenarioCase(fixtureName: fixtureName, caseName: $0.name) }
        }
    }
}

@Suite("Ranking scenarios")
struct RankingScenarioTests {
    @Test("Recorded scenarios exist")
    func fixturesExist() throws {
        #expect(try RankingFixtures.names().isEmpty == false)
    }

    @Test("Ranks and suggests as the scenario expects", arguments: RankingScenarioCase.all)
    func scenario(_ scenarioCase: RankingScenarioCase) throws {
        let fixture = try RankingFixtures.load(scenarioCase.fixtureName)
        let rankingCase = try #require(fixture.cases.first { $0.name == scenarioCase.caseName })
        let history = try #require(fixture.histories[rankingCase.history])

        let fix = LocationFix(
            latitude: fixture.fix.latitude,
            longitude: fixture.fix.longitude,
            horizontalAccuracy: rankingCase.horizontalAccuracy,
            timestamp: rankingCase.now.addingTimeInterval(-rankingCase.fixAgeSeconds)
        )
        let ranking = PlaceRanker().rank(
            candidates: fixture.places,
            fix: fix,
            history: history,
            now: rankingCase.now,
            calendar: fixture.calendar
        )
        let rankedIdentifiers = ranking.ranked.map(\.place.id)
        let leaderboard = ranking.ranked.prefix(5)
            .map { "\($0.place.name) \(String(format: "%.2f", $0.score))" }
            .joined(separator: ", ")

        if let topKey = rankingCase.expect.top {
            let expectedIdentifier = try #require(fixture.placeIdentifier(forKey: topKey))
            #expect(
                rankedIdentifiers.first == expectedIdentifier,
                "expected \(topKey) first, got \(leaderboard)"
            )
        }

        switch rankingCase.expect.suggested {
        case .noSuggestion?:
            #expect(
                ranking.suggestion == nil,
                "expected no suggestion, got \(ranking.suggestion?.name ?? "none"); \(leaderboard)"
            )
        case .place(let key)?:
            let expectedIdentifier = try #require(fixture.placeIdentifier(forKey: key))
            #expect(
                ranking.suggestion?.id == expectedIdentifier,
                "expected \(key) suggested, got \(ranking.suggestion?.name ?? "none"); \(leaderboard)"
            )
        case nil:
            break
        }

        for pair in rankingCase.expect.rankedAbove {
            let aboveKey = try #require(pair.first)
            let belowKey = try #require(pair.last)
            let above = try #require(fixture.placeIdentifier(forKey: aboveKey))
            let below = try #require(fixture.placeIdentifier(forKey: belowKey))
            let aboveIndex = try #require(rankedIdentifiers.firstIndex(of: above))
            let belowIndex = try #require(rankedIdentifiers.firstIndex(of: below))
            #expect(
                aboveIndex < belowIndex,
                "expected \(aboveKey) (#\(aboveIndex)) above \(belowKey) (#\(belowIndex)); \(leaderboard)"
            )
        }
    }
}

// MARK: - Model behavior on synthetic data

private let pacific: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    return calendar
}()

private func date(_ text: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: text)!
}

/// A block in SoMa: the fix is at the origin, and everything else is placed by
/// meters north and east of it.
private let origin = PlaceLocation(latitude: 37.7823, longitude: -122.4076)

private func location(north: Double, east: Double) -> PlaceLocation {
    PlaceLocation(
        latitude: origin.latitude + north / GeoDistance.metersPerDegreeLatitude,
        longitude: origin.longitude + east / GeoDistance.metersPerDegreeLongitude(atLatitude: origin.latitude)
    )
}

private func place(
    _ id: String,
    north: Double,
    east: Double,
    primaryType: String? = "cafe",
    types: [String] = ["cafe", "point_of_interest"],
    ratings: Int? = 500,
    viewport: PlaceViewport? = nil
) -> Place {
    Place(
        id: id,
        name: id,
        address: nil,
        location: location(north: north, east: east),
        viewport: viewport,
        types: types,
        primaryType: primaryType,
        rating: ratings == nil ? nil : 4.5,
        userRatingCount: ratings
    )
}

private func fix(accuracy: Double, now: Date, age: TimeInterval = 5) -> LocationFix {
    LocationFix(
        latitude: origin.latitude,
        longitude: origin.longitude,
        horizontalAccuracy: accuracy,
        timestamp: now.addingTimeInterval(-age)
    )
}

private func visits(at placeIdentifier: String, count: Int, hour: Int, before now: Date, everyDays: Int = 3) -> [CheckinHistoryEntry] {
    (1...count).map { index in
        var components = pacific.dateComponents([.year, .month, .day], from: now.addingTimeInterval(-Double(index * everyDays) * 86_400))
        components.hour = hour
        components.minute = 10
        return CheckinHistoryEntry(
            googlePlaceId: placeIdentifier,
            createdAt: pacific.date(from: components)!,
            placeName: placeIdentifier,
            placeTypes: ["cafe"],
            location: nil
        )
    }
}

private let tuesdayMorning = date("2026-09-22T08:30:00-07:00")

@Suite("PlaceRanker model")
struct PlaceRankerModelTests {
    let ranker = PlaceRanker()

    @Test("A tight fix ranks the nearest storefront first")
    func nearestWinsWithTightFix() {
        let candidates = [
            place("far-but-popular", north: 120, east: 0, ratings: 20_000),
            place("next-door", north: 8, east: 4, ratings: 40),
        ]
        let ranking = ranker.rank(candidates: candidates, fix: fix(accuracy: 10, now: tuesdayMorning), history: [], now: tuesdayMorning, calendar: pacific)

        #expect(ranking.ranked.map(\.place.id) == ["next-door", "far-but-popular"])
        #expect(ranking.suggestion?.id == "next-door")
    }

    @Test("Frequent visits outrank a far more popular neighbor")
    func historyBeatsPopularity() {
        let candidates = [
            place("famous", north: 15, east: 0, ratings: 30_000),
            place("my-cafe", north: -15, east: 0, ratings: 50),
        ]
        let history = visits(at: "my-cafe", count: 12, hour: 8, before: tuesdayMorning)
        let ranking = ranker.rank(candidates: candidates, fix: fix(accuracy: 20, now: tuesdayMorning), history: history, now: tuesdayMorning, calendar: pacific)

        #expect(ranking.ranked.first?.place.id == "my-cafe")
        #expect(ranking.ranked.first?.visitCount == 12)
        #expect(ranking.suggestion?.id == "my-cafe")
    }

    @Test("Visits decay with a 90-day half-life")
    func visitsDecay() {
        let recent = visits(at: "recent", count: 4, hour: 8, before: tuesdayMorning, everyDays: 2)
        let stale = visits(at: "stale", count: 4, hour: 8, before: tuesdayMorning.addingTimeInterval(-180 * 86_400), everyDays: 2)
        let statistics = HistoryStatistics(entries: recent + stale, now: tuesdayMorning, calendar: pacific, halfLifeDays: 90)

        let recentWeight = statistics.byPlace["recent"]!.decayedVisits
        let staleWeight = statistics.byPlace["stale"]!.decayedVisits
        #expect(recentWeight > 3.8)
        #expect(staleWeight < 1.1 && staleWeight > 0.9)

        let oneVisitNinetyDaysAgo = HistoryStatistics(
            entries: [CheckinHistoryEntry(googlePlaceId: "x", createdAt: tuesdayMorning.addingTimeInterval(-90 * 86_400), placeName: "x")],
            now: tuesdayMorning,
            calendar: pacific,
            halfLifeDays: 90
        )
        #expect(abs(oneVisitNinetyDaysAgo.byPlace["x"]!.decayedVisits - 0.5) < 0.001)
    }

    @Test("Morning visits count for more in the morning than at night")
    func timeOfDayAffinity() {
        let candidates = [place("my-cafe", north: 5, east: 0)]
        let history = visits(at: "my-cafe", count: 10, hour: 8, before: tuesdayMorning)
        let morning = ranker.rank(candidates: candidates, fix: fix(accuracy: 15, now: tuesdayMorning), history: history, now: tuesdayMorning, calendar: pacific)
        let night = date("2026-09-22T22:30:00-07:00")
        let evening = ranker.rank(candidates: candidates, fix: fix(accuracy: 15, now: night), history: history, now: night, calendar: pacific)

        let difference = morning.ranked[0].score - evening.ranked[0].score
        // One full swing of the time-of-day term is 2 × 1.0; decay over the
        // fourteen hours between the two evaluations is negligible.
        #expect(difference > 1.9 && difference < 2.1)
    }

    @Test("Weekend visits count for more on a weekend")
    func dayKindAffinity() {
        let candidates = [place("tailgate", north: 5, east: 0)]
        let saturday = date("2026-09-19T13:00:00-07:00")
        let history = [
            CheckinHistoryEntry(googlePlaceId: "tailgate", createdAt: date("2026-09-12T13:00:00-07:00"), placeName: "tailgate"),
            CheckinHistoryEntry(googlePlaceId: "tailgate", createdAt: date("2026-09-06T13:00:00-07:00"), placeName: "tailgate"),
            CheckinHistoryEntry(googlePlaceId: "tailgate", createdAt: date("2026-08-30T13:00:00-07:00"), placeName: "tailgate"),
        ]
        let weekend = ranker.rank(candidates: candidates, fix: fix(accuracy: 15, now: saturday), history: history, now: saturday, calendar: pacific)
        let tuesday = date("2026-09-22T13:00:00-07:00")
        let weekday = ranker.rank(candidates: candidates, fix: fix(accuracy: 15, now: tuesday), history: history, now: tuesday, calendar: pacific)

        #expect(weekend.ranked[0].score > weekday.ranked[0].score + 0.3)
    }

    @Test("A viewport larger than Google's default box becomes the venue's footprint")
    func viewportFootprint() throws {
        // The pin is a kilometer away but the box covers the fix.
        let bigBox = PlaceViewport(low: location(north: -500, east: -1500), high: location(north: 500, east: 1500))
        let airport = place("airport", north: 100, east: 1000, primaryType: "airport", types: ["airport"], ratings: 20_000, viewport: bigBox)
        let footprint = PlaceFootprint(for: airport)
        #expect(footprint.kind == .destination)
        #expect(footprint.rectangle != nil)
        #expect(footprint.effectiveDistance(from: origin, to: airport) == 0)

        // Outside the box the distance is measured to its edge, not the pin.
        let outside = location(north: 700, east: 0)
        let toEdge = try #require(footprint.effectiveDistance(from: outside, to: airport))
        #expect(abs(toEdge - 200) < 1)

        // Google's default ~250 m box is not informative.
        let defaultBox = PlaceViewport(low: location(north: -150, east: -150), high: location(north: 150, east: 150))
        let cafe = place("cafe", north: 0, east: 0, viewport: defaultBox)
        let cafeFootprint = PlaceFootprint(for: cafe)
        #expect(cafeFootprint.rectangle == nil)
        #expect(cafeFootprint.kind == .point)
        #expect(cafeFootprint.radius == PlaceFootprint.pointRadius)
    }

    @Test("A coarse fix inside a large venue ranks the venue above its storefronts")
    func coarseFixPrefersLargeVenue() {
        let bigBox = PlaceViewport(low: location(north: -1500, east: -1500), high: location(north: 1500, east: 1500))
        let candidates = [
            place("gate-cafe", north: 20, east: 0, ratings: 800),
            place("airport", north: 900, east: 600, primaryType: "airport", types: ["airport"], ratings: 20_000, viewport: bigBox),
        ]
        let coarse = ranker.rank(candidates: candidates, fix: fix(accuracy: 65, now: tuesdayMorning), history: [], now: tuesdayMorning, calendar: pacific)
        #expect(coarse.ranked.first?.place.id == "airport")

        let history = visits(at: "gate-cafe", count: 6, hour: 8, before: tuesdayMorning)
        let tight = ranker.rank(candidates: candidates, fix: fix(accuracy: 8, now: tuesdayMorning), history: history, now: tuesdayMorning, calendar: pacific)
        #expect(tight.ranked.first?.place.id == "gate-cafe")
        #expect(tight.suggestion?.id == "gate-cafe")
    }

    @Test("Parking lots and ATMs are penalized and never suggested")
    func typePriors() {
        let candidates = [
            place("lot", north: 3, east: 0, primaryType: "parking", types: ["parking"], ratings: nil),
            place("cafe", north: 20, east: 0, ratings: 300),
        ]
        let ranking = ranker.rank(candidates: candidates, fix: fix(accuracy: 10, now: tuesdayMorning), history: [], now: tuesdayMorning, calendar: pacific)

        #expect(ranking.ranked.first?.place.id == "cafe")
        #expect(ranking.ranked.last?.typePrior == -1.5)

        let onlyParking = ranker.rank(candidates: [candidates[0]], fix: fix(accuracy: 10, now: tuesdayMorning), history: [], now: tuesdayMorning, calendar: pacific)
        #expect(onlyParking.suggestion == nil)
    }

    @Test("A type prior comes from the primary type when there is one")
    func typePriorUsesPrimaryType() {
        let townHall = place("town-hall", north: 0, east: 0, primaryType: "city_hall", types: ["city_hall", "local_government_office"])
        let department = place("planning", north: 0, east: 0, primaryType: "local_government_office", types: ["local_government_office"])
        let untyped = place("office", north: 0, east: 0, primaryType: nil, types: ["corporate_office"])

        #expect(PlaceFootprint.typePrior(for: townHall) == 0)
        #expect(PlaceFootprint.typePrior(for: department) < 0)
        #expect(PlaceFootprint.typePrior(for: untyped) < 0)
    }

    @Test("A large venue type without a real viewport pays the full size price")
    func unconfirmedDestination() {
        let airport = place("airport", north: 300, east: 0, primaryType: "airport", types: ["airport"], ratings: 90)
        #expect(PlaceFootprint(for: airport).kind == .container)

        // The building the user is standing in beats a regional airport whose
        // extent Google does not know.
        let townHall = place("town-hall", north: 15, east: 0, primaryType: "city_hall", types: ["city_hall"], ratings: 1)
        let ranking = ranker.rank(
            candidates: [airport, townHall],
            fix: fix(accuracy: 30, now: tuesdayMorning),
            history: [],
            now: tuesdayMorning,
            calendar: pacific
        )
        #expect(ranking.ranked.first?.place.id == "town-hall")
    }

    @Test("A history place Google left out is added when it is close by")
    func historyInjection() {
        let candidates = [place("cafe", north: 60, east: 0, ratings: 300)]
        let history = [
            CheckinHistoryEntry(
                googlePlaceId: "my-office",
                createdAt: tuesdayMorning.addingTimeInterval(-86_400),
                placeName: "My Office",
                placePrimaryType: "corporate_office",
                placeTypes: ["corporate_office"],
                location: location(north: 10, east: 0)
            ),
            CheckinHistoryEntry(
                googlePlaceId: "far-away",
                createdAt: tuesdayMorning.addingTimeInterval(-86_400),
                placeName: "Far Away",
                location: location(north: 900, east: 0)
            ),
        ]
        let ranking = ranker.rank(candidates: candidates, fix: fix(accuracy: 20, now: tuesdayMorning), history: history, now: tuesdayMorning, calendar: pacific)

        #expect(ranking.ranked.map(\.place.id) == ["my-office", "cafe"])
        #expect(ranking.ranked.first?.place.name == "My Office")
        #expect(ranking.suggestion?.id == "my-office")
    }

    @Test("A place without a coordinate is listed last and never suggested")
    func missingLocation() {
        let nowhere = Place(id: "nowhere", name: "Nowhere", address: nil, location: nil, types: [], primaryType: nil, rating: nil, userRatingCount: 50_000)
        let ranking = ranker.rank(candidates: [nowhere, place("cafe", north: 5, east: 0)], fix: fix(accuracy: 10, now: tuesdayMorning), history: [], now: tuesdayMorning, calendar: pacific)

        #expect(ranking.ranked.last?.place.id == "nowhere")
        #expect(ranking.ranked.last?.effectiveDistance == nil)

        let alone = ranker.rank(candidates: [nowhere], fix: fix(accuracy: 10, now: tuesdayMorning), history: [], now: tuesdayMorning, calendar: pacific)
        #expect(alone.suggestion == nil)
    }

    @Test("A clear leader among many listings still shows the list")
    func suggestionNeedsProbability() {
        let leader = place("leader", north: 0, east: 0, ratings: 20_000)
        let crowded = [leader] + (1...15).map { place("tenant-\($0)", north: 5, east: 0, ratings: nil) }
        let crowdedRanking = ranker.rank(candidates: crowded, fix: fix(accuracy: 10, now: tuesdayMorning), history: [], now: tuesdayMorning, calendar: pacific)
        #expect(crowdedRanking.ranked.first?.place.id == "leader")
        #expect(crowdedRanking.ranked[0].score - crowdedRanking.ranked[1].score >= RankingWeights.standard.suggestionMinimumMargin)
        #expect(crowdedRanking.suggestion == nil)

        let quiet = Array(crowded.prefix(3))
        let quietRanking = ranker.rank(candidates: quiet, fix: fix(accuracy: 10, now: tuesdayMorning), history: [], now: tuesdayMorning, calendar: pacific)
        #expect(quietRanking.suggestion?.id == "leader")
    }

    @Test("No suggestion from a coarse, stale or invalid fix")
    func suggestionGates() {
        let candidates = [place("cafe", north: 5, east: 0, ratings: 300)]
        func suggestion(accuracy: Double, age: TimeInterval = 5) -> Place? {
            ranker.rank(candidates: candidates, fix: fix(accuracy: accuracy, now: tuesdayMorning, age: age), history: [], now: tuesdayMorning, calendar: pacific).suggestion
        }

        #expect(suggestion(accuracy: 30)?.id == "cafe")
        #expect(suggestion(accuracy: 300) == nil)
        #expect(suggestion(accuracy: 30, age: 120) == nil)
        #expect(suggestion(accuracy: -1) == nil)
    }

    @Test("Probabilities sum to one and follow the scores")
    func probabilities() {
        let candidates = [
            place("near", north: 5, east: 0),
            place("mid", north: 80, east: 0),
            place("far", north: 400, east: 0),
        ]
        let ranking = ranker.rank(candidates: candidates, fix: fix(accuracy: 10, now: tuesdayMorning), history: [], now: tuesdayMorning, calendar: pacific)

        let total = ranking.ranked.reduce(0) { $0 + $1.probability }
        #expect(abs(total - 1) < 0.0001)
        #expect(ranking.ranked[0].probability > ranking.ranked[1].probability)
        #expect(ranking.ranked[1].probability > ranking.ranked[2].probability)
    }

    @Test("Typed queries keep Google's order but float visited places")
    func queryOrdering() {
        let candidates = [place("a", north: 0, east: 0), place("b", north: 0, east: 0), place("c", north: 0, east: 0)]
        let history = [CheckinHistoryEntry(googlePlaceId: "c", createdAt: tuesdayMorning, placeName: "c")]

        let ordered = ranker.orderForQuery(candidates: candidates, history: history)

        #expect(ordered.map(\.place.id) == ["c", "a", "b"])
    }
}
