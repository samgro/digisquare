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
    types: [String] = ["cafe"],
    checkins: Int = 5,
    extent: PlaceExtent? = nil
) -> Place {
    Place(
        id: id,
        name: id,
        location: location(north: north, east: east),
        extent: extent,
        types: types,
        primaryType: primaryType,
        checkinCount: checkins
    )
}

/// An axis-aligned rectangle of grounds, in meters from the origin.
private func rectangleExtent(south: Double, west: Double, north: Double, east: Double) -> PlaceExtent {
    let southWest = location(north: south, east: west)
    let northEast = location(north: north, east: east)
    let ring = [
        southWest,
        PlaceLocation(latitude: southWest.latitude, longitude: northEast.longitude),
        northEast,
        PlaceLocation(latitude: northEast.latitude, longitude: southWest.longitude),
        southWest,
    ]
    return PlaceExtent(
        boundingBox: PlaceExtent.BoundingBox(
            south: southWest.latitude, west: southWest.longitude, north: northEast.latitude, east: northEast.longitude
        ),
        rings: [ring],
        areaSquareMeters: (north - south) * (east - west)
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
            placeId: placeIdentifier,
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
            place("far-but-popular", north: 120, east: 0, checkins: 200),
            place("next-door", north: 8, east: 4, checkins: 1),
        ]
        let ranking = ranker.rank(candidates: candidates, fix: fix(accuracy: 10, now: tuesdayMorning), history: [], now: tuesdayMorning, calendar: pacific)

        #expect(ranking.ranked.map(\.place.id) == ["next-door", "far-but-popular"])
        #expect(ranking.suggestion?.id == "next-door")
    }

    @Test("Frequent visits outrank a far more popular neighbor")
    func historyBeatsPopularity() {
        let candidates = [
            place("famous", north: 15, east: 0, checkins: 300),
            place("my-cafe", north: -15, east: 0, checkins: 2),
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
            entries: [CheckinHistoryEntry(placeId: "x", createdAt: tuesdayMorning.addingTimeInterval(-90 * 86_400), placeName: "x")],
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
            CheckinHistoryEntry(placeId: "tailgate", createdAt: date("2026-09-12T13:00:00-07:00"), placeName: "tailgate"),
            CheckinHistoryEntry(placeId: "tailgate", createdAt: date("2026-09-06T13:00:00-07:00"), placeName: "tailgate"),
            CheckinHistoryEntry(placeId: "tailgate", createdAt: date("2026-08-30T13:00:00-07:00"), placeName: "tailgate"),
        ]
        let weekend = ranker.rank(candidates: candidates, fix: fix(accuracy: 15, now: saturday), history: history, now: saturday, calendar: pacific)
        let tuesday = date("2026-09-22T13:00:00-07:00")
        let weekday = ranker.rank(candidates: candidates, fix: fix(accuracy: 15, now: tuesday), history: history, now: tuesday, calendar: pacific)

        #expect(weekend.ranked[0].score > weekday.ranked[0].score + 0.3)
    }

    @Test("A large venue's footprint comes from its category")
    func categoryFootprint() throws {
        let airport = place("airport", north: 100, east: 1000, primaryType: "airport", types: ["airport"])
        let footprint = PlaceFootprint(for: airport)
        #expect(footprint.kind == .destination)
        #expect(footprint.radius == 1500)
        // Inside the disc the distance is zero; outside it is measured to its edge.
        #expect(footprint.effectiveDistance(from: origin, to: airport) == 0)
        let outside = location(north: 100, east: -700)
        let toEdge = try #require(footprint.effectiveDistance(from: outside, to: airport))
        #expect(abs(toEdge - 200) < 1)

        let park = place("park", north: 0, east: 0, primaryType: "park", types: ["park"])
        #expect(PlaceFootprint(for: park).kind == .container)
        #expect(PlaceFootprint(for: park).radius == 150)

        let cafe = place("cafe", north: 0, east: 0)
        #expect(PlaceFootprint(for: cafe).kind == .point)
        #expect(PlaceFootprint(for: cafe).radius == PlaceFootprint.pointRadius)
    }

    @Test("Recorded grounds become the footprint: zero inside, distance to the edge outside")
    func polygonFootprint() throws {
        // The pin is a kilometer away but the grounds cover the fix.
        let grounds = rectangleExtent(south: -500, west: -1500, north: 500, east: 1500)
        let airport = place("airport", north: 100, east: 1000, primaryType: "airport", types: ["airport"], extent: grounds)
        let footprint = PlaceFootprint(for: airport)
        #expect(footprint.kind == .destination)
        #expect(footprint.polygon != nil)
        #expect(abs(footprint.radius - 500) < 1)
        #expect(footprint.effectiveDistance(from: origin, to: airport) == 0)

        // Outside the grounds the distance is measured to their edge, not the pin.
        let outside = location(north: 700, east: 0)
        let toEdge = try #require(footprint.effectiveDistance(from: outside, to: airport))
        #expect(abs(toEdge - 200) < 1)
        let corner = location(north: 800, east: 1900)
        let toCorner = try #require(footprint.effectiveDistance(from: corner, to: airport))
        #expect(abs(toCorner - 500) < 1)

        // A building outline is not informative; the storefront radius stands.
        let outline = rectangleExtent(south: -20, west: -30, north: 20, east: 30)
        let cafe = place("cafe", north: 0, east: 0, extent: outline)
        #expect(PlaceFootprint(for: cafe).polygon == nil)
        #expect(PlaceFootprint(for: cafe).kind == .point)

        // Big grounds around something the table calls a storefront make it a container.
        let campus = rectangleExtent(south: -400, west: -400, north: 400, east: 400)
        let office = place("office", north: 0, east: 0, primaryType: "corporate_office", types: ["corporate_office"], extent: campus)
        #expect(PlaceFootprint(for: office).kind == .container)
    }

    @Test("Inside an airport's recorded grounds the airport is suggested over the gate's storefronts, even from a tight fix")
    func insideDestinationGrounds() {
        // SFO-sized grounds, pin 900 m away; a cafe, a bookstore and a check-in
        // counter within a few meters, none with any checkins.
        let grounds = rectangleExtent(south: -1200, west: -2500, north: 1200, east: 800)
        let airport = place("sfo", north: 0, east: -900, primaryType: "airport", types: ["airport"], checkins: 0, extent: grounds)
        let cafe = place("cafe", north: 16, east: 0, primaryType: "cafe", types: ["cafe"], checkins: 0)
        let books = place("books", north: 0, east: 18, primaryType: "bookstore", types: ["bookstore"], checkins: 0)
        let counter = place("counter", north: -20, east: 5, primaryType: "airport", types: ["airport"], checkins: 0)

        for accuracy in [5.0, 65.0] {
            let ranking = ranker.rank(candidates: [cafe, books, counter, airport], fix: fix(accuracy: accuracy, now: tuesdayMorning), history: [], now: tuesdayMorning, calendar: pacific)
            #expect(ranking.ranked.first?.place.id == "sfo", "accuracy \(accuracy)")
            #expect(ranking.suggestion?.id == "sfo", "accuracy \(accuracy)")
        }

        // Without the grounds the airport is a 1.5 km disc around a pin 900 m
        // off: still in reach, but not the answer from a tight fix.
        let pinOnly = place("sfo", north: 0, east: -900, primaryType: "airport", types: ["airport"], checkins: 0)
        let tight = ranker.rank(candidates: [cafe, books, counter, pinOnly], fix: fix(accuracy: 5, now: tuesdayMorning), history: [], now: tuesdayMorning, calendar: pacific)
        #expect(tight.ranked.first?.place.id != "sfo")

        // A regular's morning cafe still wins over the airport around it.
        let regular = ranker.rank(
            candidates: [cafe, books, counter, airport],
            fix: fix(accuracy: 5, now: tuesdayMorning),
            history: visits(at: "cafe", count: 6, hour: 7, before: tuesdayMorning),
            now: tuesdayMorning,
            calendar: pacific
        )
        #expect(regular.ranked.first?.place.id == "cafe")
    }

    @Test("Recorded grounds keep a venue in the running 1.3 km from its pin")
    func groundsBeatDistanceToPin() {
        // A park whose pin is 1.3 km west of the fix, with grounds that reach
        // 200 m past it; a museum 30 m away, as the de Young sits in Golden
        // Gate Park.
        let parkGrounds = rectangleExtent(south: -300, west: -1500, north: 300, east: 200)
        let park = place("park", north: 0, east: -1300, primaryType: "park", types: ["park"], checkins: 40, extent: parkGrounds)
        let museum = place("museum", north: 30, east: 0, primaryType: "museum", types: ["museum"], checkins: 20)

        // At the museum's door the museum is the more specific answer, but the
        // park is inside its grounds too (distance zero) and close enough
        // behind that the picker shows the list instead of jumping to the
        // museum.
        let atMuseum = ranker.rank(candidates: [museum, park], fix: fix(accuracy: 65, now: tuesdayMorning), history: [], now: tuesdayMorning, calendar: pacific)
        #expect(atMuseum.ranked.map(\.place.id) == ["museum", "park"])
        #expect(atMuseum.ranked[1].effectiveDistance == 0)
        #expect(atMuseum.ranked[0].score - atMuseum.ranked[1].score < RankingWeights.standard.suggestionMinimumMargin)
        #expect(atMuseum.suggestion == nil)

        // Without the polygon the park is judged from its pin, over a kilometer
        // off, and is nowhere near.
        let pinOnly = place("park", north: 0, east: -1300, primaryType: "park", types: ["park"], checkins: 40)
        let withoutGrounds = ranker.rank(candidates: [museum, pinOnly], fix: fix(accuracy: 65, now: tuesdayMorning), history: [], now: tuesdayMorning, calendar: pacific)
        #expect((withoutGrounds.ranked[1].effectiveDistance ?? 0) > 1000)
        #expect(withoutGrounds.ranked[0].score - withoutGrounds.ranked[1].score > 5)

        // Deeper in the grounds, away from the museum, the park wins outright
        // and is suggested, even from a coarse fix.
        let inTheGrounds = location(north: 0, east: -600)
        let deeper = LocationFix(
            latitude: inTheGrounds.latitude,
            longitude: inTheGrounds.longitude,
            horizontalAccuracy: 65,
            timestamp: tuesdayMorning.addingTimeInterval(-5)
        )
        let awayFromMuseum = ranker.rank(candidates: [museum, park], fix: deeper, history: [], now: tuesdayMorning, calendar: pacific)
        #expect(awayFromMuseum.ranked.first?.place.id == "park")
        #expect(awayFromMuseum.suggestion?.id == "park")
    }

    @Test("Overture's specific museum and stadium categories fold onto the generic entry")
    func suffixCategories() {
        let artMuseum = place("art", north: 0, east: 0, primaryType: "art_museum", types: ["art_museum"])
        #expect(PlaceFootprint(for: artMuseum).kind == .container)
        #expect(PlaceFootprint(for: artMuseum).radius == 60)

        let ballpark = place("ballpark", north: 0, east: 0, primaryType: "baseball_stadium", types: ["baseball_stadium"])
        #expect(PlaceFootprint(for: ballpark).kind == .destination)
        #expect(PlaceFootprint(for: ballpark).radius == 300)
    }

    @Test("A footprint is judged on the primary category, not the alternates")
    func footprintUsesPrimaryCategory() {
        // A restaurant inside an airport lists the airport among its
        // alternates; it is still a restaurant, and a storefront.
        let terminalRestaurant = place("tacos", north: 0, east: 0, primaryType: "mexican_restaurant", types: ["mexican_restaurant", "airport"])
        #expect(PlaceFootprint(for: terminalRestaurant).kind == .point)

        // Only a place with no primary category is judged on its alternates.
        let untyped = place("somewhere", north: 0, east: 0, primaryType: nil, types: ["shopping", "park"])
        #expect(PlaceFootprint(for: untyped).kind == .container)
        #expect(PlaceFootprint(for: untyped).radius == 150)
    }

    @Test("A coarse fix inside a large venue ranks the venue above its storefronts")
    func coarseFixPrefersLargeVenue() {
        let candidates = [
            place("gate-cafe", north: 20, east: 0, checkins: 8),
            place("airport", north: 900, east: 600, primaryType: "airport", types: ["airport"], checkins: 40),
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
            place("lot", north: 3, east: 0, primaryType: "parking", types: ["parking"], checkins: 0),
            place("cafe", north: 20, east: 0, checkins: 30),
        ]
        let ranking = ranker.rank(candidates: candidates, fix: fix(accuracy: 10, now: tuesdayMorning), history: [], now: tuesdayMorning, calendar: pacific)

        #expect(ranking.ranked.first?.place.id == "cafe")
        #expect(ranking.ranked.last?.typePrior == -1.5)

        let onlyParking = ranker.rank(candidates: [candidates[0]], fix: fix(accuracy: 10, now: tuesdayMorning), history: [], now: tuesdayMorning, calendar: pacific)
        #expect(onlyParking.suggestion == nil)
    }

    @Test("A type prior comes from the primary type when there is one")
    func typePriorUsesPrimaryType() {
        let townHall = place("town-hall", north: 0, east: 0, primaryType: "town_hall", types: ["town_hall", "local_and_state_government_offices"])
        let department = place("planning", north: 0, east: 0, primaryType: "local_and_state_government_offices", types: ["local_and_state_government_offices"])
        let untyped = place("office", north: 0, east: 0, primaryType: nil, types: ["corporate_office"])

        #expect(PlaceFootprint.typePrior(for: townHall) == 0)
        #expect(PlaceFootprint.typePrior(for: department) < 0)
        #expect(PlaceFootprint.typePrior(for: untyped) < 0)
    }

    @Test("A regional airport's guessed footprint does not swallow the building next door")
    func destinationBesideStorefront() {
        // Every airport is modeled as a 1.5 km disc, so the town hall is
        // "inside" the airfield. The building the user is standing at still
        // wins on distance and size.
        let airport = place("airport", north: 900, east: 0, primaryType: "airport", types: ["airport"], checkins: 3)
        let townHall = place("town-hall", north: 15, east: 0, primaryType: "town_hall", types: ["town_hall"], checkins: 1)
        let ranking = ranker.rank(
            candidates: [airport, townHall],
            fix: fix(accuracy: 30, now: tuesdayMorning),
            history: [],
            now: tuesdayMorning,
            calendar: pacific
        )
        #expect(ranking.ranked.first?.place.id == "town-hall")
    }

    @Test("A history place the search left out is added when it is close by")
    func historyInjection() {
        let candidates = [place("cafe", north: 60, east: 0, checkins: 30)]
        let history = [
            CheckinHistoryEntry(
                placeId: "my-office",
                createdAt: tuesdayMorning.addingTimeInterval(-86_400),
                placeName: "My Office",
                placePrimaryType: "corporate_office",
                placeTypes: ["corporate_office"],
                location: location(north: 10, east: 0)
            ),
            CheckinHistoryEntry(
                placeId: "far-away",
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
        let nowhere = Place(id: "nowhere", name: "Nowhere", location: nil, checkinCount: 500)
        let ranking = ranker.rank(candidates: [nowhere, place("cafe", north: 5, east: 0)], fix: fix(accuracy: 10, now: tuesdayMorning), history: [], now: tuesdayMorning, calendar: pacific)

        #expect(ranking.ranked.last?.place.id == "nowhere")
        #expect(ranking.ranked.last?.effectiveDistance == nil)

        let alone = ranker.rank(candidates: [nowhere], fix: fix(accuracy: 10, now: tuesdayMorning), history: [], now: tuesdayMorning, calendar: pacific)
        #expect(alone.suggestion == nil)
    }

    @Test("A clear leader among many listings still shows the list")
    func suggestionNeedsProbability() {
        let leader = place("leader", north: 0, east: 0, checkins: 300)
        let crowded = [leader] + (1...15).map { place("tenant-\($0)", north: 5, east: 0, checkins: 0) }
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
        let candidates = [place("cafe", north: 5, east: 0, checkins: 30)]
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

    @Test("Typed queries keep the server's order but float visited places")
    func queryOrdering() {
        let candidates = [place("a", north: 0, east: 0), place("b", north: 0, east: 0), place("c", north: 0, east: 0)]
        let history = [CheckinHistoryEntry(placeId: "c", createdAt: tuesdayMorning, placeName: "c")]

        let ordered = ranker.orderForQuery(candidates: candidates, history: history)

        #expect(ordered.map(\.place.id) == ["c", "a", "b"])
    }
}
