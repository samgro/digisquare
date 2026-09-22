//
//  FrequentPlaceDetectorTests.swift
//  HackysackTests
//

import Foundation
import Testing
@testable import Hackysack

@Suite("Home/work detection")
struct FrequentPlaceDetectorTests {
    typealias Reason = FrequentPlaceDetector.Reason

    // MARK: Scenarios

    /// Sleeps at home every night, works at the office on `officeWeekdays`, and
    /// grabs a quick coffee before work.
    private func commuter(
        now: Date = VisitScenarioBuilder.defaultNow,
        dayCount: Int = 56,
        seed: UInt64 = 7,
        home: ScenarioSpot = ScenarioSpots.home,
        officeWeekdays: Set<Int> = VisitScenarioBuilder.weekdays,
        officeDays: Range<Int>? = nil,
        homeDays: Range<Int>? = nil,
        includeCoffee: Bool = true
    ) -> VisitScenarioBuilder {
        var builder = VisitScenarioBuilder(seed: seed, now: now, dayCount: dayCount)
        builder.addHomeNights(at: home, days: homeDays ?? builder.days)
        builder.addWorkdays(at: ScenarioSpots.office, days: officeDays ?? builder.days, weekdays: officeWeekdays)
        if includeCoffee {
            builder.addWorkdays(at: ScenarioSpots.coffeeShop, days: builder.days, from: 8.25, to: 8.85)
        }
        return builder
    }

    private func habitualClusters(_ builder: VisitScenarioBuilder) -> [FrequentPlaceDetector.ClusterSummary] {
        builder.summaries().filter(\.isHabitual)
    }

    // MARK: 1. The everyday commuter

    @Test func commuterHomeAndOfficeAreSuppressedButCoffeeIsSuggested() {
        var builder = commuter()

        let atHome = builder.assessArrival(at: ScenarioSpots.home)
        #expect(atHome.reason == .habitualPlace(.home))
        #expect(!atHome.shouldSuggest)

        let atOffice = builder.assessArrival(at: ScenarioSpots.office)
        #expect(atOffice.reason == .habitualPlace(.work))
        #expect(!atOffice.shouldSuggest)

        let atCoffee = builder.assessArrival(at: ScenarioSpots.coffeeShop)
        #expect(atCoffee.reason == .notHabitual)
        #expect(atCoffee.shouldSuggest)

        let habitual = habitualClusters(builder)
        #expect(habitual.count == 2)
        #expect(habitual.filter { $0.role == .home }.count == 1)
        #expect(habitual.filter { $0.role == .work }.count == 1)
    }

    @Test func homeLongDaysComeFromNightsAndOfficeFromWeekdays() {
        let builder = commuter()
        let home = builder.summary(near: ScenarioSpots.home)
        let office = builder.summary(near: ScenarioSpots.office)
        #expect((home?.longDays ?? 0) >= 50)
        #expect((home?.overnightFraction ?? 0) >= 0.9)
        #expect((office?.longDays ?? 0) >= 38)
        #expect(office?.overnightLongDays == 0)
        #expect((builder.summary(near: ScenarioSpots.coffeeShop)?.longDays ?? 0) == 0)
    }

    // MARK: 2. Noisy indoor fixes

    @Test func poorIndoorAccuracyStillMakesOneHome() {
        let noisyHome = ScenarioSpots.home.withNoise(positionJitterMeters: 250, accuracy: 300...300)
        var builder = commuter(home: noisyHome)

        let atHome = builder.assessArrival(at: noisyHome)
        #expect(atHome.reason == .habitualPlace(.home))

        let homeClusters = habitualClusters(builder).filter { $0.centroid.distance(to: noisyHome.coordinate) <= 400 }
        #expect(homeClusters.count == 1)
    }

    // MARK: 3. Hybrid and part-time schedules

    @Test func threeAndTwoOfficeDaysAWeekAreWorkButOneIsNot() {
        var threeDays = commuter(officeWeekdays: [2, 3, 4])
        #expect(threeDays.assessArrival(at: ScenarioSpots.office).reason == .habitualPlace(.work))

        var twoDays = commuter(officeWeekdays: [3, 5])
        #expect(twoDays.assessArrival(at: ScenarioSpots.office).reason == .habitualPlace(.work))

        var oneDay = commuter(officeWeekdays: [4])
        let assessment = oneDay.assessArrival(at: ScenarioSpots.office)
        #expect(assessment.reason == .notHabitual)
        #expect(assessment.shouldSuggest)
    }

    // MARK: 4 & 5. Coffee shops and coworking

    @Test func threeHoursADayAtACoffeeShopIsStillSuggested() {
        var builder = VisitScenarioBuilder()
        builder.addHomeNights(days: builder.days)
        builder.addWorkdays(at: ScenarioSpots.coffeeShop, days: builder.days, from: 8, to: 11)

        let assessment = builder.assessArrival(at: ScenarioSpots.coffeeShop)
        #expect(assessment.reason == .notHabitual)
        #expect(assessment.shouldSuggest)
    }

    @Test func coworkingAllDayIsWorkUnlessTheUserChecksInThere() {
        var withoutCheckins = VisitScenarioBuilder()
        withoutCheckins.addHomeNights(days: withoutCheckins.days)
        withoutCheckins.addWorkdays(at: ScenarioSpots.coffeeShop, days: withoutCheckins.days, from: 9, to: 15)
        #expect(withoutCheckins.assessArrival(at: ScenarioSpots.coffeeShop).reason == .habitualPlace(.work))

        var withCheckins = withoutCheckins
        for day in [10, 25, 40] {
            withCheckins.addCheckin(at: ScenarioSpots.coffeeShop, googlePlaceId: "wework-1", day: day, hour: 9.5)
        }
        let assessment = withCheckins.assessArrival(at: ScenarioSpots.coffeeShop)
        #expect(assessment.reason == .regularCheckinSpot(googlePlaceId: "wework-1"))
        #expect(assessment.shouldSuggest)
    }

    @Test func aSingleCheckinIsNotEnoughToOverrideWork() {
        var builder = VisitScenarioBuilder()
        builder.addHomeNights(days: builder.days)
        builder.addWorkdays(at: ScenarioSpots.coffeeShop, days: builder.days, from: 9, to: 15)
        builder.addCheckin(at: ScenarioSpots.coffeeShop, googlePlaceId: "wework-1", day: 30, hour: 9.5)
        #expect(builder.assessArrival(at: ScenarioSpots.coffeeShop).reason == .habitualPlace(.work))
    }

    // MARK: 6 & 7. Vacations

    @Test func aTwoWeekTripDoesNotBreakHomeAndTheHotelIsNotHome() {
        var builder = VisitScenarioBuilder()
        let tripDays = 21..<35
        builder.addHomeNights(days: builder.days.filter { !tripDays.contains($0) })
        builder.addWorkdays(at: ScenarioSpots.office, days: builder.days.filter { !tripDays.contains($0) })
        builder.addVisit(at: ScenarioSpots.hotel, day: tripDays.lowerBound, from: 15, to: Double(tripDays.count - 1) * 24 + 11)

        #expect(builder.assessArrival(at: ScenarioSpots.home).reason == .habitualPlace(.home))
        #expect(builder.assessArrival(at: ScenarioSpots.office).reason == .habitualPlace(.work))

        let atHotel = builder.assessArrival(at: ScenarioSpots.hotel)
        #expect(atHotel.reason == .notHabitual)
        #expect((builder.summary(near: ScenarioSpots.hotel)?.longDays ?? 0) >= 13)
    }

    @Test func aTenNightHotelStayIsNotHome() {
        var builder = commuter()
        builder.addVisit(at: ScenarioSpots.hotel, day: 30, from: 15, to: 10 * 24 + 11)
        #expect(builder.assessArrival(at: ScenarioSpots.hotel).reason == .notHabitual)
    }

    @Test func homeIsStillHomeTheDayYouGetBackFromTwoWeeksAway() {
        var builder = VisitScenarioBuilder()
        let awayDays = 42..<56
        builder.addHomeNights(days: builder.days.filter { !awayDays.contains($0) })
        builder.addWorkdays(at: ScenarioSpots.office, days: builder.days.filter { !awayDays.contains($0) })
        builder.addVisit(at: ScenarioSpots.hotel, day: awayDays.lowerBound, from: 15, to: Double(awayDays.count - 1) * 24 + 6)

        #expect(builder.assessArrival(at: ScenarioSpots.home).reason == .habitualPlace(.home))
        #expect(builder.assessArrival(at: ScenarioSpots.office).reason == .habitualPlace(.work))
    }

    // MARK: 8. Moving house

    @Test func aNewHomeTakesThreeWeeksToLearn() {
        var justMoved = VisitScenarioBuilder()
        justMoved.addHomeNights(at: ScenarioSpots.home, days: 0..<42)
        justMoved.addHomeNights(at: ScenarioSpots.newHome, days: 42..<56)
        justMoved.addWorkdays(at: ScenarioSpots.office, days: justMoved.days)

        let atNewHome = justMoved.assessArrival(at: ScenarioSpots.newHome)
        #expect(atNewHome.reason == .notHabitual)
        #expect(atNewHome.shouldSuggest)
        #expect(justMoved.assessArrival(at: ScenarioSpots.home).reason == .habitualPlace(.home))

        var threeWeeksLater = VisitScenarioBuilder(dayCount: 77)
        threeWeeksLater.addHomeNights(at: ScenarioSpots.home, days: 0..<42)
        threeWeeksLater.addHomeNights(at: ScenarioSpots.newHome, days: 42..<77)
        threeWeeksLater.addWorkdays(at: ScenarioSpots.office, days: threeWeeksLater.days)
        #expect(threeWeeksLater.assessArrival(at: ScenarioSpots.newHome).reason == .habitualPlace(.home))
    }

    // MARK: 9. Two homes, and places the user said no to

    /// Own place Sunday to Thursday nights, the partner's place from Friday
    /// evening to Sunday lunchtime, office on weekdays.
    private func twoHomes() -> VisitScenarioBuilder {
        var builder = VisitScenarioBuilder()
        let ownPlaceNights = builder.days.filter { (1...5).contains(builder.weekday(of: $0)) }
        builder.addHomeNights(days: ownPlaceNights, weekendDaytime: false)
        for day in builder.days where builder.weekday(of: day) == 6 {
            builder.addVisit(at: ScenarioSpots.partnerHome, day: day, from: 21, to: 60)
        }
        builder.addWorkdays(at: ScenarioSpots.office, days: builder.days)
        return builder
    }

    @Test func aPartnersPlaceTwoNightsAWeekIsASecondHome() {
        var builder = twoHomes()

        #expect(builder.assessArrival(at: ScenarioSpots.home).reason == .habitualPlace(.home))
        #expect(builder.assessArrival(at: ScenarioSpots.partnerHome).reason == .habitualPlace(.home))
        #expect(builder.assessArrival(at: ScenarioSpots.office).reason == .habitualPlace(.work))

        let habitual = habitualClusters(builder)
        #expect(habitual.count == 3)
        #expect(habitual.filter { $0.role == .home }.count == 2)
    }

    @Test func anOccasionalNightAtAFriendsIsSuggested() {
        var builder = twoHomes()
        for day in [10, 40] {
            builder.addVisit(at: ScenarioSpots.friendHome, day: day, from: 20, to: 34)
        }
        let assessment = builder.assessArrival(at: ScenarioSpots.friendHome)
        #expect(assessment.reason == .notHabitual)
        #expect(assessment.shouldSuggest)
    }

    @Test func removingASuggestionSnoozesThePlaceAndRemovingTwiceSilencesIt() {
        var base = twoHomes()
        for day in [10, 40] {
            base.addVisit(at: ScenarioSpots.friendHome, day: day, from: 20, to: 34)
        }

        var recentlyRemoved = base
        recentlyRemoved.addRejection(at: ScenarioSpots.friendHome, daysAgo: 10)
        let snoozed = recentlyRemoved.assessArrival(at: ScenarioSpots.friendHome)
        #expect(snoozed.reason == .rejectedRecently)
        #expect(!snoozed.shouldSuggest)

        var removedLongAgo = base
        removedLongAgo.addRejection(at: ScenarioSpots.friendHome, daysAgo: 40)
        #expect(removedLongAgo.assessArrival(at: ScenarioSpots.friendHome).shouldSuggest)

        var removedTwice = base
        removedTwice.addRejection(at: ScenarioSpots.friendHome, daysAgo: 40)
        removedTwice.addRejection(at: ScenarioSpots.friendHome, daysAgo: 10)
        let silenced = removedTwice.assessArrival(at: ScenarioSpots.friendHome)
        #expect(silenced.reason == .rejectedRepeatedly)
        #expect(!silenced.shouldSuggest)
    }

    @Test func removalsWinOverTheCheckinExemption() {
        var builder = commuter()
        builder.addCheckin(at: ScenarioSpots.coffeeShop, googlePlaceId: "cafe-1", day: 20, hour: 8.5)
        builder.addCheckin(at: ScenarioSpots.coffeeShop, googlePlaceId: "cafe-1", day: 30, hour: 8.5)
        builder.addRejection(at: ScenarioSpots.coffeeShop, daysAgo: 3)
        #expect(builder.assessArrival(at: ScenarioSpots.coffeeShop).reason == .rejectedRecently)
    }

    // MARK: 10. Two jobs

    @Test func twoPartTimeJobsAreBothWork() {
        var builder = VisitScenarioBuilder()
        builder.addHomeNights(days: builder.days)
        builder.addWorkdays(at: ScenarioSpots.office, days: builder.days, weekdays: [2, 3, 4])
        builder.addWorkdays(at: ScenarioSpots.secondOffice, days: builder.days, weekdays: [5, 6], from: 10, to: 16)

        #expect(builder.assessArrival(at: ScenarioSpots.office).reason == .habitualPlace(.work))
        #expect(builder.assessArrival(at: ScenarioSpots.secondOffice).reason == .habitualPlace(.work))
        #expect(builder.assessArrival(at: ScenarioSpots.home).reason == .habitualPlace(.home))

        let habitual = habitualClusters(builder)
        #expect(habitual.count == 3)
        #expect(habitual.filter { $0.role == .work }.count == 2)
    }

    // MARK: 11. Stepping out and coming back

    @Test func aLunchBreakDoesNotSplitTheWorkday() {
        var builder = VisitScenarioBuilder()
        builder.addHomeNights(days: builder.days)
        builder.addWorkdays(at: ScenarioSpots.office, days: builder.days, awayBreak: (startHour: 12, durationHours: 1))
        builder.addWorkdays(at: ScenarioSpots.lunchSpot, days: builder.days, from: 12.1, to: 12.9)

        #expect(builder.assessArrival(at: ScenarioSpots.office).reason == .habitualPlace(.work))
        let atLunch = builder.assessArrival(at: ScenarioSpots.lunchSpot)
        #expect(atLunch.reason == .notHabitual)
        #expect(atLunch.shouldSuggest)
    }

    @Test func aBreakLongerThanTwoHoursSplitsTheDayIntoShortStays() {
        var builder = VisitScenarioBuilder()
        builder.addHomeNights(days: builder.days)
        // Three hours rather than two and a bit, so the ±20 minute jitter on
        // each edge can never pull the gap under the two-hour bridge.
        builder.addWorkdays(at: ScenarioSpots.office, days: builder.days, awayBreak: (startHour: 12, durationHours: 3))

        let assessment = builder.assessArrival(at: ScenarioSpots.office)
        #expect(assessment.reason == .notHabitual)
        #expect((builder.summary(near: ScenarioSpots.office)?.longDays ?? 0) == 0)
    }

    @Test func anEveningErrandDoesNotBreakAnOvernightStay() {
        var builder = VisitScenarioBuilder()
        for day in builder.days {
            builder.addStay(at: ScenarioSpots.home, day: day, from: 18.5, to: 32, awayBreak: (startHour: 20, durationHours: 0.75))
            builder.addVisit(at: ScenarioSpots.supermarket, day: day, from: 20.1, to: 20.6)
        }
        let home = builder.summary(near: ScenarioSpots.home)
        #expect(home?.role == .home)
        #expect((home?.overnightFraction ?? 0) >= 0.9)
        #expect(builder.assessArrival(at: ScenarioSpots.supermarket).shouldSuggest)
    }

    // MARK: 12. Night shifts

    @Test func aNightShiftHospitalIsWorkAndTheDaytimeHomeIsHome() {
        var builder = VisitScenarioBuilder()
        for day in builder.days {
            let weekday = builder.weekday(of: day)
            if (1...5).contains(weekday) {
                builder.addVisit(at: ScenarioSpots.hospital, day: day, from: 22, to: 30.5)
            }
            switch weekday {
            case 2...5:
                builder.addVisit(at: ScenarioSpots.home, day: day, from: 7.5, to: 21.5)
            case 6:
                builder.addVisit(at: ScenarioSpots.home, day: day, from: 7.5, to: 48 + 21.5)
            default:
                break
            }
        }

        #expect(builder.assessArrival(at: ScenarioSpots.hospital).reason == .habitualPlace(.work))
        #expect(builder.assessArrival(at: ScenarioSpots.home).reason == .habitualPlace(.home))
    }

    // MARK: 13. Working from home, short stops, and thin history

    @Test func workingFromHomeYieldsOnlyAHome() {
        var builder = VisitScenarioBuilder()
        for day in builder.days {
            builder.addVisit(at: ScenarioSpots.home, day: day, from: 0, to: 24, timeJitterMinutes: 0)
            if [3, 7].contains(builder.weekday(of: day)) {
                builder.addVisit(at: ScenarioSpots.supermarket, day: day, from: 11, to: 11.33, timeJitterMinutes: 0)
            }
            if [2, 3, 5, 7].contains(builder.weekday(of: day)) {
                builder.addVisit(at: ScenarioSpots.gym, day: day, from: 17, to: 18, timeJitterMinutes: 0)
            }
        }

        #expect(builder.assessArrival(at: ScenarioSpots.home).reason == .habitualPlace(.home))
        #expect(builder.assessArrival(at: ScenarioSpots.supermarket).shouldSuggest)
        #expect(builder.assessArrival(at: ScenarioSpots.gym).shouldSuggest)
        #expect(habitualClusters(builder).count == 1)
    }

    @Test func fiveDaysOfHistoryIsNotEnoughToSuppressAnything() {
        var builder = commuter(dayCount: 5)
        #expect(builder.assessArrival(at: ScenarioSpots.home).shouldSuggest)
        #expect(builder.assessArrival(at: ScenarioSpots.office).shouldSuggest)
    }

    // MARK: 14. Daylight saving time

    @Test func theClockChangeDoesNotChangeTheVerdict() {
        let midNovember = VisitScenarioBuilder.date(year: 2026, month: 11, day: 15, hour: 8, minute: 20)
        var builder = commuter(now: midNovember)
        #expect(builder.assessArrival(at: ScenarioSpots.home).reason == .habitualPlace(.home))
        #expect(builder.assessArrival(at: ScenarioSpots.office).reason == .habitualPlace(.work))
        #expect((builder.summary(near: ScenarioSpots.home)?.longDays ?? 0) >= 50)
        #expect((builder.summary(near: ScenarioSpots.office)?.longDays ?? 0) >= 38)
    }

    // MARK: 15. Duplicate deliveries and noise

    @Test func doubleDeliveriesDoNotDoubleTheDwell() {
        let single = commuter()
        // Core Location reports each visit on arrival and again on departure; a
        // poor fix can put the second delivery tens of meters away.
        let copies = single.visits.map { visit in
            VisitRecord(
                coordinate: GeoCoordinate(latitude: visit.coordinate.latitude + 0.0007, longitude: visit.coordinate.longitude),
                horizontalAccuracy: visit.horizontalAccuracy,
                arrivalDate: visit.arrivalDate.addingTimeInterval(20),
                departureDate: visit.departureDate?.addingTimeInterval(20)
            )
        }
        let summaries = FrequentPlaceDetector().clusterSummaries(
            history: single.visits + copies,
            now: single.now,
            calendar: single.calendar
        )
        let home = summaries.first { $0.centroid.distance(to: ScenarioSpots.home.coordinate) <= 400 }
        let office = summaries.first { $0.centroid.distance(to: ScenarioSpots.office.coordinate) <= 400 }
        #expect(home?.longDays == single.summary(near: ScenarioSpots.home)?.longDays)
        #expect(office?.longDays == single.summary(near: ScenarioSpots.office)?.longDays)
        #expect(home?.role == .home)
        #expect(office?.role == .work)
    }

    @Test func eightMinuteStopsNeverAddUpToAnything() {
        var builder = commuter()
        for day in builder.days where !builder.isWeekend(day) {
            builder.addVisit(at: ScenarioSpots.busStop, day: day, from: 8, to: 8.13, timeJitterMinutes: 0)
            builder.addVisit(at: ScenarioSpots.busStop, day: day, from: 18, to: 18.13, timeJitterMinutes: 0)
        }
        let assessment = builder.assessArrival(at: ScenarioSpots.busStop)
        #expect(assessment.reason == .notHabitual)
        #expect(assessment.shouldSuggest)
        // Sub-ten-minute stops never even form a cluster; the nearest cluster
        // within 400 m would be home, 300 m away, so look tighter than that.
        #expect(builder.summary(near: ScenarioSpots.busStop, within: 150) == nil)
    }

    @Test func visitsWithHopelessAccuracyAreIgnored() {
        let vague = ScenarioSpots.park.withNoise(positionJitterMeters: 40, accuracy: 1500...1500)
        var builder = commuter()
        for day in builder.days {
            builder.addVisit(at: vague, day: day, from: 12, to: 20)
        }
        #expect(builder.summary(near: ScenarioSpots.park) == nil)
    }

    // MARK: 16. Lost departures, midnight, and ongoing stays

    @Test func aRecordWithNoDepartureIsCutOffAtTheNextArrival() {
        var builder = commuter()
        let parkArrival = builder.date(day: 36, hour: 14)
        let stale = VisitRecord(
            coordinate: ScenarioSpots.park.coordinate,
            horizontalAccuracy: 40,
            arrivalDate: parkArrival,
            departureDate: nil
        )
        let history = builder.visits + [stale]
        let detector = FrequentPlaceDetector()
        let summaries = detector.clusterSummaries(history: history, now: builder.now, calendar: builder.calendar)
        let park = summaries.first { $0.centroid.distance(to: ScenarioSpots.park.coordinate) <= 400 }
        #expect(park != nil)
        #expect((park?.totalDwell ?? 0) < 6 * 3600)
        #expect(park?.isHabitual == false)

        let atHome = builder.assessArrival(at: ScenarioSpots.home)
        #expect(atHome.reason == .habitualPlace(.home))
    }

    @Test func aStayAcrossMidnightCountsForBothDays() {
        let builder = VisitScenarioBuilder()
        let visit = VisitRecord(
            coordinate: ScenarioSpots.friendHome.coordinate,
            horizontalAccuracy: 30,
            arrivalDate: builder.date(day: 20, hour: 18),
            departureDate: builder.date(day: 20, hour: 33)
        )
        let summaries = FrequentPlaceDetector().clusterSummaries(history: [visit], now: builder.now, calendar: builder.calendar)
        #expect(summaries.count == 1)
        #expect(summaries.first?.longDays == 2)
        #expect(summaries.first?.overnightLongDays == 1)
    }

    @Test func anOngoingVisitCountsUpToNow() {
        let builder = VisitScenarioBuilder()
        let visit = VisitRecord(
            coordinate: ScenarioSpots.friendHome.coordinate,
            horizontalAccuracy: 30,
            arrivalDate: builder.now.addingTimeInterval(-6 * 3600),
            departureDate: nil
        )
        let summaries = FrequentPlaceDetector().clusterSummaries(currentVisit: visit, history: [], now: builder.now, calendar: builder.calendar)
        #expect(summaries.first?.longDays == 1)
        #expect(summaries.first?.containsCurrentVisit == true)
    }

    // MARK: Clustering

    @Test func nearbyFixesMergeAndDistantPlacesStaySeparate() {
        var builder = VisitScenarioBuilder()
        builder.addHomeNights(days: builder.days)
        builder.addWorkdays(at: ScenarioSpots.office, days: builder.days, from: 9, to: 12)
        builder.addWorkdays(at: ScenarioSpots.lunchSpot, days: builder.days, from: 12.2, to: 12.9)

        let summaries = builder.summaries()
        #expect(summaries.filter { $0.centroid.distance(to: ScenarioSpots.home.coordinate) <= 400 }.count == 1)
        #expect(summaries.filter { $0.centroid.distance(to: ScenarioSpots.office.coordinate) <= 150 }.count == 1)
        #expect(summaries.filter { $0.centroid.distance(to: ScenarioSpots.lunchSpot.coordinate) <= 150 }.count == 1)
    }

    @Test func aWideFixJoinsItsClusterButAPreciseFarOneDoesNot() {
        let detector = FrequentPlaceDetector()
        let base = ScenarioSpots.home.coordinate
        let wide = VisitRecord(
            coordinate: GeoCoordinate(latitude: base.latitude + 0.0022, longitude: base.longitude),
            horizontalAccuracy: 280,
            arrivalDate: VisitScenarioBuilder.defaultNow.addingTimeInterval(-3600)
        )
        #expect(detector.joinRadius(for: wide) == 280)
        let precise = VisitRecord(
            coordinate: wide.coordinate,
            horizontalAccuracy: 20,
            arrivalDate: wide.arrivalDate
        )
        #expect(detector.joinRadius(for: precise) == 150)
        #expect(wide.coordinate.distance(to: base) > 150)
        #expect(wide.coordinate.distance(to: base) < 280)
    }
}
