//
//  VisitProcessorTests.swift
//  HackysackTests
//

import Foundation
import Testing
@testable import Hackysack

@Suite("Visit processing")
struct VisitProcessorTests {
    private struct Harness {
        let builder: VisitScenarioBuilder
        let history: VisitHistoryStore
        let store: CheckinStore
        let processor: VisitProcessor

        var today: Int { builder.dayCount }
    }

    private static let nearbyPlaces: [Place] = [
        Place(
            id: "cafe-1",
            name: "Four Barrel Coffee",
            address: "375 Valencia St, San Francisco, CA 94103, USA",
            location: PlaceLocation(latitude: 37.7670, longitude: -122.4220),
            types: ["cafe"],
            primaryType: "coffee_shop",
            rating: 4.4,
            userRatingCount: 2100
        ),
        Place(
            id: "bakery-1",
            name: "Tartine Bakery",
            address: "600 Guerrero St, San Francisco, CA 94110, USA",
            location: PlaceLocation(latitude: 37.7614, longitude: -122.4241),
            types: ["bakery"],
            primaryType: "bakery",
            rating: 4.5,
            userRatingCount: 8000
        ),
    ]

    private func makeHarness(
        places: [Place] = VisitProcessorTests.nearbyPlaces,
        lookupError: Error? = nil
    ) -> Harness {
        var builder = VisitScenarioBuilder()
        builder.addHomeNights(days: builder.days)
        builder.addWorkdays(at: ScenarioSpots.office, days: builder.days)
        let history = VisitHistoryStore.inMemory(
            snapshot: VisitHistoryStore.Snapshot(visits: builder.visits, checkins: builder.checkins, rejections: builder.rejections)
        )
        let store = CheckinStore.inMemory(visitHistory: history)
        let processor = VisitProcessor(
            visitHistory: history,
            checkinStore: store,
            calendar: builder.calendar,
            lookupPlaces: { _, _ in
                if let lookupError { throw lookupError }
                return places
            }
        )
        return Harness(builder: builder, history: history, store: store, processor: processor)
    }

    private func arrival(_ harness: Harness, at spot: ScenarioSpot, hour: Double) -> VisitRecord {
        VisitRecord(
            coordinate: spot.coordinate,
            horizontalAccuracy: 40,
            arrivalDate: harness.builder.date(day: harness.today, hour: hour),
            departureDate: nil
        )
    }

    private func departure(_ harness: Harness, at spot: ScenarioSpot, arrivalHour: Double, departureHour: Double) -> VisitRecord {
        VisitRecord(
            coordinate: spot.coordinate,
            horizontalAccuracy: 40,
            arrivalDate: harness.builder.date(day: harness.today, hour: arrivalHour),
            departureDate: harness.builder.date(day: harness.today, hour: departureHour)
        )
    }

    private func isSuggested(_ outcome: VisitProcessor.Outcome) -> Bool {
        if case .suggested = outcome { return true }
        return false
    }

    @Test func arrivingSomewhereNewSuggestsTheMostPopularPlaceWithTheRestAsAlternatives() async {
        let harness = makeHarness()
        let visit = arrival(harness, at: ScenarioSpots.coffeeShop, hour: 10)

        let outcome = await harness.processor.process(visit, now: visit.arrivalDate.addingTimeInterval(300))

        #expect(isSuggested(outcome))
        #expect(harness.store.suggestions.count == 1)
        #expect(harness.store.suggestions.first?.selectedPlace?.id == "cafe-1")
        #expect(harness.store.suggestions.first?.alternativePlaces.map(\.id) == ["bakery-1"])
        #expect(harness.store.suggestions.first?.visibility == .everyone)
        #expect(harness.store.timelineEntries.first?.syncStatus == .suggested)
    }

    @Test func arrivingHomeIsSuppressed() async {
        let harness = makeHarness()
        let visit = arrival(harness, at: ScenarioSpots.home, hour: 19)

        let outcome = await harness.processor.process(visit, now: visit.arrivalDate.addingTimeInterval(300))

        #expect(outcome == .suppressed(.habitualPlace(.home)))
        #expect(harness.store.suggestions.isEmpty)
    }

    @Test func theDepartureDeliveryUpdatesTheSuggestionsVisit() async {
        let harness = makeHarness()
        let visit = arrival(harness, at: ScenarioSpots.coffeeShop, hour: 10)
        await harness.processor.process(visit, now: visit.arrivalDate.addingTimeInterval(300))

        let leaving = departure(harness, at: ScenarioSpots.coffeeShop, arrivalHour: 10, departureHour: 12)
        let outcome = await harness.processor.process(leaving, now: leaving.departureDate!)

        #expect(outcome == .updatedExistingSuggestion)
        #expect(harness.store.suggestions.count == 1)
        #expect(harness.store.suggestions.first?.visit.departureDate == leaving.departureDate)
    }

    @Test func aStayThatTurnsOutToBeUnderTenMinutesIsWithdrawn() async {
        let harness = makeHarness()
        let visit = arrival(harness, at: ScenarioSpots.coffeeShop, hour: 10)
        await harness.processor.process(visit, now: visit.arrivalDate.addingTimeInterval(60))

        let leaving = departure(harness, at: ScenarioSpots.coffeeShop, arrivalHour: 10, departureHour: 10.1)
        let outcome = await harness.processor.process(leaving, now: leaving.departureDate!)

        #expect(outcome == .withdrewSuggestion)
        #expect(harness.store.suggestions.isEmpty)
        #expect(harness.history.rejections.isEmpty)
    }

    @Test func comingBackWithinTwoHoursExtendsTheSameSuggestion() async {
        let harness = makeHarness()
        let visit = arrival(harness, at: ScenarioSpots.coffeeShop, hour: 10)
        await harness.processor.process(visit, now: visit.arrivalDate.addingTimeInterval(300))
        let leaving = departure(harness, at: ScenarioSpots.coffeeShop, arrivalHour: 10, departureHour: 12)
        await harness.processor.process(leaving, now: leaving.departureDate!)

        let back = arrival(harness, at: ScenarioSpots.coffeeShop, hour: 13)
        let outcome = await harness.processor.process(back, now: back.arrivalDate.addingTimeInterval(300))

        #expect(outcome == .extendedSuggestion)
        #expect(harness.store.suggestions.count == 1)
        #expect(harness.store.suggestions.first?.visit.departureDate == nil)

        let leavingAgain = departure(harness, at: ScenarioSpots.coffeeShop, arrivalHour: 13, departureHour: 15)
        let laterOutcome = await harness.processor.process(leavingAgain, now: leavingAgain.departureDate!)
        #expect(laterOutcome == .updatedExistingSuggestion)
        #expect(harness.store.suggestions.first?.visit.departureDate == leavingAgain.departureDate)
    }

    @Test func comingBackAfterThreeHoursIsANewSuggestion() async {
        let harness = makeHarness()
        let visit = arrival(harness, at: ScenarioSpots.coffeeShop, hour: 10)
        await harness.processor.process(visit, now: visit.arrivalDate.addingTimeInterval(300))
        let leaving = departure(harness, at: ScenarioSpots.coffeeShop, arrivalHour: 10, departureHour: 12)
        await harness.processor.process(leaving, now: leaving.departureDate!)

        let back = arrival(harness, at: ScenarioSpots.coffeeShop, hour: 15.5)
        let outcome = await harness.processor.process(back, now: back.arrivalDate.addingTimeInterval(300))

        #expect(isSuggested(outcome))
        #expect(harness.store.suggestions.count == 2)
    }

    @Test func aPlaceYouCheckedIntoAnHourAgoIsNotSuggestedAgain() async {
        let harness = makeHarness()
        let visit = arrival(harness, at: ScenarioSpots.coffeeShop, hour: 10)
        await harness.processor.process(visit, now: visit.arrivalDate.addingTimeInterval(300))
        harness.store.accept(suggestionId: harness.store.suggestions[0].id)
        // Accepting posts to the API asynchronously; the history records the
        // checkin on success, which the test stands in for here.
        harness.history.recordCheckin(
            VisitedPlaceEvent(coordinate: ScenarioSpots.coffeeShop.coordinate, googlePlaceId: "cafe-1", date: visit.arrivalDate)
        )
        let leaving = departure(harness, at: ScenarioSpots.coffeeShop, arrivalHour: 10, departureHour: 12)
        await harness.processor.process(leaving, now: leaving.departureDate!)

        let back = arrival(harness, at: ScenarioSpots.coffeeShop, hour: 13)
        let outcome = await harness.processor.process(back, now: back.arrivalDate.addingTimeInterval(300))

        #expect(outcome == .alreadyCheckedIn)
        #expect(harness.store.suggestions.isEmpty)
    }

    @Test func removingASuggestionIsRememberedAsARejection() async {
        let harness = makeHarness()
        let visit = arrival(harness, at: ScenarioSpots.coffeeShop, hour: 10)
        await harness.processor.process(visit, now: visit.arrivalDate.addingTimeInterval(300))

        harness.store.remove(suggestionId: harness.store.suggestions[0].id, now: visit.arrivalDate.addingTimeInterval(600))

        #expect(harness.store.suggestions.isEmpty)
        #expect(harness.history.rejections.count == 1)

        let tomorrow = VisitRecord(
            coordinate: ScenarioSpots.coffeeShop.coordinate,
            horizontalAccuracy: 40,
            arrivalDate: visit.arrivalDate.addingTimeInterval(24 * 3600)
        )
        let outcome = await harness.processor.process(tomorrow, now: tomorrow.arrivalDate.addingTimeInterval(300))
        #expect(outcome == .suppressed(.rejectedRecently))
    }

    @Test func nothingNearbyMeansNoSuggestion() async {
        let harness = makeHarness(places: [])
        let visit = arrival(harness, at: ScenarioSpots.coffeeShop, hour: 10)
        let outcome = await harness.processor.process(visit, now: visit.arrivalDate.addingTimeInterval(300))
        #expect(outcome == .noPlacesFound)
        #expect(harness.store.suggestions.isEmpty)
    }

    @Test func aFailedLookupIsNotACrashAndLeavesNoSuggestion() async {
        struct LookupFailure: Error {}
        let harness = makeHarness(lookupError: LookupFailure())
        let visit = arrival(harness, at: ScenarioSpots.coffeeShop, hour: 10)
        let outcome = await harness.processor.process(visit, now: visit.arrivalDate.addingTimeInterval(300))
        #expect(outcome == .noPlacesFound)
        #expect(harness.history.visits.contains { $0.id == visit.id })
    }

    @Test func confirmingAnAlternativeMakesItTheSelectedPlace() async {
        let harness = makeHarness()
        let visit = arrival(harness, at: ScenarioSpots.coffeeShop, hour: 10)
        await harness.processor.process(visit, now: visit.arrivalDate.addingTimeInterval(300))
        let suggestion = harness.store.suggestions[0]
        harness.store.setVisibility(.onlyMe, forSuggestion: suggestion.id)

        harness.store.confirm(suggestionId: suggestion.id, place: suggestion.alternativePlaces[0])

        #expect(harness.store.suggestions.isEmpty)
        let saved = harness.store.savedEntries.first
        #expect(saved?.syncStatus == .saving)
        #expect(saved?.draft?.googlePlaceId == "bakery-1")
        #expect(saved?.draft?.visibility == .onlyMe)
        #expect(saved?.draft?.source == .visit)
        #expect(saved?.draft?.createdAt == visit.arrivalDate)
        #expect(saved?.checkin.createdAt == visit.arrivalDate)
    }
}
