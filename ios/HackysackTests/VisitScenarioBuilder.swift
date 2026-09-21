//
//  VisitScenarioBuilder.swift
//  HackysackTests
//

import Foundation
@testable import Hackysack

/// SplitMix64. Deterministic, so a scenario built with the same seed is the
/// same scenario on every run.
struct SeededRandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func nextValue() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return mixed ^ (mixed >> 31)
    }

    /// Uniform in `[0, 1)`.
    mutating func nextUnitDouble() -> Double {
        Double(nextValue() >> 11) / Double(1 << 53)
    }

    mutating func nextDouble(in range: ClosedRange<Double>) -> Double {
        range.lowerBound + (range.upperBound - range.lowerBound) * nextUnitDouble()
    }
}

/// A named place that generated visits scatter around.
struct ScenarioSpot {
    let name: String
    let coordinate: GeoCoordinate
    /// How far a generated fix can land from the true coordinate.
    var positionJitterMeters: Double = 40
    /// The reported horizontal accuracy of generated fixes.
    var accuracyRange: ClosedRange<Double> = 20...120

    func withNoise(positionJitterMeters: Double, accuracy: ClosedRange<Double>) -> ScenarioSpot {
        ScenarioSpot(name: name, coordinate: coordinate, positionJitterMeters: positionJitterMeters, accuracyRange: accuracy)
    }
}

/// Real-world-ish coordinates, all far enough apart to be distinct clusters
/// except where a test says otherwise.
enum ScenarioSpots {
    static let home = ScenarioSpot(name: "home", coordinate: GeoCoordinate(latitude: 37.7599, longitude: -122.4148))
    /// About 600 m from home.
    static let coffeeShop = ScenarioSpot(name: "coffee shop", coordinate: GeoCoordinate(latitude: 37.7599, longitude: -122.4216))
    /// About 300 m from home.
    static let busStop = ScenarioSpot(name: "bus stop", coordinate: GeoCoordinate(latitude: 37.7626, longitude: -122.4148))
    /// About 900 m from home.
    static let supermarket = ScenarioSpot(name: "supermarket", coordinate: GeoCoordinate(latitude: 37.7520, longitude: -122.4180))
    static let gym = ScenarioSpot(name: "gym", coordinate: GeoCoordinate(latitude: 37.7670, longitude: -122.4290))
    static let office = ScenarioSpot(name: "office", coordinate: GeoCoordinate(latitude: 37.7897, longitude: -122.4010))
    /// About 400 m from the office.
    static let lunchSpot = ScenarioSpot(name: "lunch spot", coordinate: GeoCoordinate(latitude: 37.7897, longitude: -122.4055))
    static let secondOffice = ScenarioSpot(name: "second office", coordinate: GeoCoordinate(latitude: 37.7846, longitude: -122.4090))
    static let partnerHome = ScenarioSpot(name: "partner's home", coordinate: GeoCoordinate(latitude: 37.8044, longitude: -122.2712))
    static let friendHome = ScenarioSpot(name: "friend's home", coordinate: GeoCoordinate(latitude: 37.7749, longitude: -122.4194))
    static let hospital = ScenarioSpot(name: "hospital", coordinate: GeoCoordinate(latitude: 37.7630, longitude: -122.4580))
    static let park = ScenarioSpot(name: "park", coordinate: GeoCoordinate(latitude: 37.7694, longitude: -122.4862))
    static let hotel = ScenarioSpot(name: "hotel", coordinate: GeoCoordinate(latitude: 34.0522, longitude: -118.2437))
    static let newHome = ScenarioSpot(name: "new home", coordinate: GeoCoordinate(latitude: 37.7415, longitude: -122.4335))
}

/// Lays out weeks of visits on a fixed calendar so detector tests can describe
/// a person's routine ("home every night, office on weekdays, a coffee every
/// morning") and assert what the detector makes of it. Times and positions
/// get seeded jitter so the data looks like Core Location produced it.
struct VisitScenarioBuilder {
    static let timeZone = TimeZone(identifier: "America/Los_Angeles")!

    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    /// Monday 2026-09-21 08:20 Pacific.
    static let defaultNow = date(year: 2026, month: 9, day: 21, hour: 8, minute: 20)

    static func date(year: Int, month: Int, day: Int, hour: Int, minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    let calendar: Calendar
    let now: Date
    let dayCount: Int
    /// Local midnight `dayCount` days before `now`. Scenario day 0.
    let windowStart: Date

    private(set) var visits: [VisitRecord] = []
    private(set) var checkins: [VisitedPlaceEvent] = []
    private(set) var rejections: [RemovedSuggestion] = []
    private var random: SeededRandomNumberGenerator

    init(seed: UInt64 = 7, now: Date = VisitScenarioBuilder.defaultNow, dayCount: Int = 56, calendar: Calendar = VisitScenarioBuilder.calendar) {
        self.calendar = calendar
        self.now = now
        self.dayCount = dayCount
        windowStart = calendar.date(byAdding: .day, value: -dayCount, to: calendar.startOfDay(for: now))!
        random = SeededRandomNumberGenerator(seed: seed)
    }

    // MARK: Calendar helpers

    var days: Range<Int> { 0..<dayCount }

    /// `hour` may exceed 24 to reach into the following day.
    func date(day: Int, hour: Double) -> Date {
        calendar.date(byAdding: .day, value: day, to: windowStart)!.addingTimeInterval(hour * 3600)
    }

    /// 1 = Sunday … 7 = Saturday.
    func weekday(of day: Int) -> Int {
        calendar.component(.weekday, from: date(day: day, hour: 12))
    }

    func isWeekend(_ day: Int) -> Bool {
        [1, 7].contains(weekday(of: day))
    }

    static let weekdays: Set<Int> = [2, 3, 4, 5, 6]

    // MARK: Noise

    mutating func jitteredCoordinate(around spot: ScenarioSpot) -> GeoCoordinate {
        let bearing = random.nextUnitDouble() * 2 * Double.pi
        let distance = random.nextUnitDouble() * spot.positionJitterMeters
        let metersPerDegreeLatitude = 111_320.0
        let metersPerDegreeLongitude = metersPerDegreeLatitude * cos(spot.coordinate.latitude * Double.pi / 180)
        return GeoCoordinate(
            latitude: spot.coordinate.latitude + distance * cos(bearing) / metersPerDegreeLatitude,
            longitude: spot.coordinate.longitude + distance * sin(bearing) / metersPerDegreeLongitude
        )
    }

    mutating func accuracy(for spot: ScenarioSpot) -> Double {
        random.nextDouble(in: spot.accuracyRange)
    }

    private mutating func jitteredMinutes(_ maximum: Double) -> TimeInterval {
        random.nextDouble(in: -maximum...maximum) * 60
    }

    // MARK: Visits

    /// One completed visit. `endHour` may exceed 24 to cross midnight.
    @discardableResult
    mutating func addVisit(
        at spot: ScenarioSpot,
        day: Int,
        from startHour: Double,
        to endHour: Double,
        timeJitterMinutes: Double = 20
    ) -> VisitRecord {
        let arrival = date(day: day, hour: startHour).addingTimeInterval(jitteredMinutes(timeJitterMinutes))
        var departure = date(day: day, hour: endHour).addingTimeInterval(jitteredMinutes(timeJitterMinutes))
        if departure <= arrival {
            departure = arrival.addingTimeInterval(60)
        }
        let visit = VisitRecord(
            coordinate: jitteredCoordinate(around: spot),
            horizontalAccuracy: accuracy(for: spot),
            arrivalDate: arrival,
            departureDate: departure
        )
        visits.append(visit)
        return visit
    }

    /// A stay optionally split into two visits by a break away from the place,
    /// e.g. leaving the office for lunch.
    mutating func addStay(
        at spot: ScenarioSpot,
        day: Int,
        from startHour: Double,
        to endHour: Double,
        awayBreak: (startHour: Double, durationHours: Double)? = nil,
        timeJitterMinutes: Double = 20
    ) {
        guard let awayBreak else {
            addVisit(at: spot, day: day, from: startHour, to: endHour, timeJitterMinutes: timeJitterMinutes)
            return
        }
        addVisit(at: spot, day: day, from: startHour, to: awayBreak.startHour, timeJitterMinutes: timeJitterMinutes)
        addVisit(
            at: spot,
            day: day,
            from: awayBreak.startHour + awayBreak.durationHours,
            to: endHour,
            timeJitterMinutes: timeJitterMinutes
        )
    }

    /// A visit that is still in progress: what the processor assesses on arrival.
    mutating func currentVisit(at spot: ScenarioSpot, arrivedMinutesAgo: Double = 5) -> VisitRecord {
        VisitRecord(
            coordinate: jitteredCoordinate(around: spot),
            horizontalAccuracy: accuracy(for: spot),
            arrivalDate: now.addingTimeInterval(-arrivedMinutesAgo * 60),
            departureDate: nil,
            receivedAt: now
        )
    }

    mutating func addCheckin(at spot: ScenarioSpot, googlePlaceId: String, day: Int, hour: Double) {
        checkins.append(
            VisitedPlaceEvent(coordinate: jitteredCoordinate(around: spot), googlePlaceId: googlePlaceId, date: date(day: day, hour: hour))
        )
    }

    mutating func addRejection(at spot: ScenarioSpot, daysAgo: Int) {
        rejections.append(
            RemovedSuggestion(
                coordinate: jitteredCoordinate(around: spot),
                date: now.addingTimeInterval(-TimeInterval(daysAgo) * 24 * 3600)
            )
        )
    }

    mutating func removeVisits(where shouldRemove: (VisitRecord) -> Bool) {
        visits.removeAll(where: shouldRemove)
    }

    // MARK: Routines

    /// Sleeps at `spot` every night in `days`: arrives in the evening and leaves
    /// the next morning. Weekend days also get a daytime block at home.
    mutating func addHomeNights(
        at spot: ScenarioSpot = ScenarioSpots.home,
        days: some Sequence<Int>,
        arriveHour: Double = 18.5,
        departHour: Double = 32,
        weekendDaytime: Bool = true
    ) {
        for day in days {
            addVisit(at: spot, day: day, from: arriveHour, to: departHour)
            if weekendDaytime, isWeekend(day) {
                addVisit(at: spot, day: day, from: 10, to: 17)
            }
        }
    }

    /// A workday block on the given weekdays, optionally split by a break.
    mutating func addWorkdays(
        at spot: ScenarioSpot,
        days: some Sequence<Int>,
        weekdays: Set<Int> = VisitScenarioBuilder.weekdays,
        from startHour: Double = 9,
        to endHour: Double = 17.5,
        awayBreak: (startHour: Double, durationHours: Double)? = nil
    ) {
        for day in days where weekdays.contains(weekday(of: day)) {
            addStay(at: spot, day: day, from: startHour, to: endHour, awayBreak: awayBreak)
        }
    }

    // MARK: Running the detector

    func assess(_ visit: VisitRecord, detector: FrequentPlaceDetector = FrequentPlaceDetector()) -> FrequentPlaceDetector.Assessment {
        detector.assess(
            visit: visit,
            history: visits,
            checkins: checkins,
            rejections: rejections,
            now: now,
            calendar: calendar
        )
    }

    /// Assesses arriving at `spot` right now.
    mutating func assessArrival(
        at spot: ScenarioSpot,
        arrivedMinutesAgo: Double = 5,
        detector: FrequentPlaceDetector = FrequentPlaceDetector()
    ) -> FrequentPlaceDetector.Assessment {
        let visit = currentVisit(at: spot, arrivedMinutesAgo: arrivedMinutesAgo)
        return assess(visit, detector: detector)
    }

    func summaries(currentVisit: VisitRecord? = nil, detector: FrequentPlaceDetector = FrequentPlaceDetector()) -> [FrequentPlaceDetector.ClusterSummary] {
        detector.clusterSummaries(currentVisit: currentVisit, history: visits, now: now, calendar: calendar)
    }

    /// The cluster whose centroid is closest to `spot`, if one is within 400 m.
    func summary(near spot: ScenarioSpot, detector: FrequentPlaceDetector = FrequentPlaceDetector()) -> FrequentPlaceDetector.ClusterSummary? {
        summaries(detector: detector)
            .filter { $0.centroid.distance(to: spot.coordinate) <= 400 }
            .min { $0.centroid.distance(to: spot.coordinate) < $1.centroid.distance(to: spot.coordinate) }
    }
}
