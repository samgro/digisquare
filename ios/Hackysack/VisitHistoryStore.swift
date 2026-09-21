//
//  VisitHistoryStore.swift
//  Hackysack
//

import Foundation

/// Persists everything the home/work detector needs to learn from: the visits
/// Core Location has reported, the places the user has confirmed checkins at,
/// and the suggestions they removed. Core Location does not backfill visits,
/// so this history starts accumulating on first launch.
@MainActor
final class VisitHistoryStore {
    struct Snapshot: Codable, Equatable {
        var visits: [VisitRecord] = []
        var checkins: [VisitedPlaceEvent] = []
        var rejections: [RemovedSuggestion] = []
    }

    struct RecordResult: Equatable {
        let record: VisitRecord
        /// False when the delivery matched a visit already on file (Core Location
        /// reports each visit on arrival and again on departure).
        let isNew: Bool
    }

    /// Two deliveries this close in arrival time are the same visit. Two distinct
    /// visits can never start within a minute of each other.
    static let duplicateArrivalTolerance: TimeInterval = 60
    /// A sanity bound on the duplicate rule: a poor fix can move the departure
    /// delivery a few hundred meters, but never across town.
    static let duplicateDistanceTolerance: Double = 500

    /// Visits and checkins older than this are dropped. Rejections are kept,
    /// since a removed suggestion should stay removed.
    static let retentionDays = 90

    private(set) var snapshot: Snapshot
    private let fileStore: JSONFileStore<Snapshot>?

    var visits: [VisitRecord] { snapshot.visits }
    var checkins: [VisitedPlaceEvent] { snapshot.checkins }
    var rejections: [RemovedSuggestion] { snapshot.rejections }

    init(fileStore: JSONFileStore<Snapshot>? = JSONFileStore(fileName: "visit-history.json")) {
        self.fileStore = fileStore
        snapshot = fileStore?.load() ?? Snapshot()
    }

    /// A store that never touches disk, for previews and tests.
    static func inMemory(snapshot: Snapshot = Snapshot()) -> VisitHistoryStore {
        let store = VisitHistoryStore(fileStore: nil)
        store.snapshot = snapshot
        return store
    }

    /// Files a delivery. A repeat of a known visit updates that visit's departure
    /// (and keeps the better of the two accuracies) instead of adding a second
    /// record. A genuinely new arrival also closes any older record that never
    /// got a departure, since the user is evidently no longer there.
    @discardableResult
    func record(_ visit: VisitRecord) -> RecordResult {
        if let index = snapshot.visits.firstIndex(where: { existing in
            abs(existing.arrivalDate.timeIntervalSince(visit.arrivalDate)) <= Self.duplicateArrivalTolerance
                && existing.coordinate.distance(to: visit.coordinate) <= Self.duplicateDistanceTolerance
        }) {
            var existing = snapshot.visits[index]
            if let departureDate = visit.departureDate {
                existing.departureDate = departureDate
            }
            if visit.horizontalAccuracy < existing.horizontalAccuracy {
                existing.horizontalAccuracy = visit.horizontalAccuracy
                existing.coordinate = visit.coordinate
            }
            existing.receivedAt = max(existing.receivedAt, visit.receivedAt)
            snapshot.visits[index] = existing
            persist()
            return RecordResult(record: existing, isNew: false)
        }

        for index in snapshot.visits.indices
        where snapshot.visits[index].departureDate == nil && snapshot.visits[index].arrivalDate < visit.arrivalDate {
            snapshot.visits[index].departureDate = visit.arrivalDate
        }
        snapshot.visits.append(visit)
        persist()
        return RecordResult(record: visit, isNew: true)
    }

    func visit(withId id: UUID) -> VisitRecord? {
        snapshot.visits.first { $0.id == id }
    }

    func recordCheckin(_ event: VisitedPlaceEvent) {
        snapshot.checkins.append(event)
        persist()
    }

    func recordRejection(_ rejection: RemovedSuggestion) {
        snapshot.rejections.append(rejection)
        persist()
    }

    /// Drops visits and checkins that have aged out of the retention window.
    func prune(now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-TimeInterval(Self.retentionDays) * 24 * 60 * 60)
        snapshot.visits.removeAll { ($0.departureDate ?? $0.arrivalDate) < cutoff }
        snapshot.checkins.removeAll { $0.date < cutoff }
        persist()
    }

    private func persist() {
        fileStore?.save(snapshot)
    }
}
