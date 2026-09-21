//
//  VisitHistoryStoreTests.swift
//  HackysackTests
//

import Foundation
import Testing
@testable import Hackysack

@Suite("Visit history")
struct VisitHistoryStoreTests {
    private let coordinate = GeoCoordinate(latitude: 37.7599, longitude: -122.4148)
    private let arrival = VisitScenarioBuilder.date(year: 2026, month: 9, day: 20, hour: 14)

    private func visit(arrivalOffset: TimeInterval = 0, departureOffset: TimeInterval? = nil, accuracy: Double = 50, latitudeOffset: Double = 0) -> VisitRecord {
        VisitRecord(
            coordinate: GeoCoordinate(latitude: coordinate.latitude + latitudeOffset, longitude: coordinate.longitude),
            horizontalAccuracy: accuracy,
            arrivalDate: arrival.addingTimeInterval(arrivalOffset),
            departureDate: departureOffset.map { arrival.addingTimeInterval($0) }
        )
    }

    @Test func theDepartureDeliveryUpdatesTheArrivalRecordInsteadOfAddingOne() {
        let store = VisitHistoryStore.inMemory()
        let first = store.record(visit())
        #expect(first.isNew)

        let second = store.record(visit(arrivalOffset: 15, departureOffset: 2 * 3600, latitudeOffset: 0.0007))
        #expect(!second.isNew)
        #expect(second.record.id == first.record.id)
        #expect(store.visits.count == 1)
        #expect(store.visits[0].departureDate == arrival.addingTimeInterval(2 * 3600))
    }

    @Test func theBetterFixWins() {
        let store = VisitHistoryStore.inMemory()
        store.record(visit(accuracy: 300))
        store.record(visit(arrivalOffset: 5, departureOffset: 3600, accuracy: 30, latitudeOffset: 0.0003))
        #expect(store.visits[0].horizontalAccuracy == 30)
        #expect(store.visits[0].coordinate.latitude == coordinate.latitude + 0.0003)
    }

    @Test func aNewArrivalIsAFreshRecordAndClosesAStaleOpenOne() {
        let store = VisitHistoryStore.inMemory()
        store.record(visit())
        let later = store.record(visit(arrivalOffset: 4 * 3600, latitudeOffset: 0.02))
        #expect(later.isNew)
        #expect(store.visits.count == 2)
        #expect(store.visits[0].departureDate == arrival.addingTimeInterval(4 * 3600))
        #expect(store.visits[1].departureDate == nil)
    }

    @Test func arrivalsMoreThanAMinuteApartAreDifferentVisits() {
        let store = VisitHistoryStore.inMemory()
        store.record(visit(departureOffset: 3600))
        store.record(visit(arrivalOffset: 90, departureOffset: 7200))
        #expect(store.visits.count == 2)
    }

    @Test func pruningDropsOldVisitsAndCheckinsButKeepsRejections() {
        let store = VisitHistoryStore.inMemory()
        let now = VisitScenarioBuilder.defaultNow
        let old = now.addingTimeInterval(-100 * 24 * 3600)
        store.record(VisitRecord(coordinate: coordinate, horizontalAccuracy: 40, arrivalDate: old, departureDate: old.addingTimeInterval(3600)))
        store.record(visit(departureOffset: 3600))
        store.recordCheckin(VisitedPlaceEvent(coordinate: coordinate, googlePlaceId: "cafe", date: old))
        store.recordCheckin(VisitedPlaceEvent(coordinate: coordinate, googlePlaceId: "cafe", date: arrival))
        store.recordRejection(RemovedSuggestion(coordinate: coordinate, date: old))

        store.prune(now: now)

        #expect(store.visits.count == 1)
        #expect(store.checkins.count == 1)
        #expect(store.rejections.count == 1)
    }

    @Test func theSnapshotRoundTripsThroughDisk() {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileStore = JSONFileStore<VisitHistoryStore.Snapshot>(fileURL: directory.appending(path: "visit-history.json"))

        let store = VisitHistoryStore(fileStore: fileStore)
        store.record(visit(departureOffset: 3600))
        store.recordCheckin(VisitedPlaceEvent(coordinate: coordinate, googlePlaceId: "cafe", date: arrival))
        store.recordRejection(RemovedSuggestion(coordinate: coordinate, date: arrival))

        let reloaded = VisitHistoryStore(fileStore: fileStore)
        #expect(reloaded.snapshot == store.snapshot)
    }

    @Test func anUnreadableFileIsTreatedAsEmpty() {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appending(path: "visit-history.json")
        try? Data("not json".utf8).write(to: fileURL)

        let store = VisitHistoryStore(fileStore: JSONFileStore(fileURL: fileURL))
        #expect(store.visits.isEmpty)
    }
}
