//
//  VisitProcessor.swift
//  Hackysack
//

import CoreLocation
import Foundation
import UIKit
import os

extension VisitRecord {
    /// Maps a Core Location visit onto the plain record the rest of the app
    /// uses. Core Location marks an unknown arrival with `.distantPast` (when
    /// monitoring started mid-stay) and an unknown departure with
    /// `.distantFuture` (the user is still there); both become sensible values.
    init(visit: CLVisit, receivedAt: Date) {
        let hasKnownArrival = visit.arrivalDate != .distantPast
        self.init(
            coordinate: GeoCoordinate(latitude: visit.coordinate.latitude, longitude: visit.coordinate.longitude),
            horizontalAccuracy: visit.horizontalAccuracy,
            arrivalDate: hasKnownArrival ? visit.arrivalDate : receivedAt,
            departureDate: visit.departureDate == .distantFuture ? nil : visit.departureDate,
            receivedAt: receivedAt,
            hasKnownArrival: hasKnownArrival
        )
    }
}

/// Turns visit deliveries into pending checkin suggestions.
///
/// One instance lives for the whole app so a background relaunch for a visit
/// event has somewhere to send it. The Places lookup is injected so the
/// pipeline can be tested without the network.
@MainActor
final class VisitProcessor {
    enum Outcome: Equatable {
        /// A repeat delivery (normally the departure) for a visit we already know.
        case updatedExistingSuggestion
        /// The completed visit was too short to have been a real stay.
        case withdrewSuggestion
        /// The user came back to a place they only just left; same stay.
        case extendedSuggestion
        /// The user already checked in during this stay.
        case alreadyCheckedIn
        /// The detector decided this is not a place to suggest.
        case suppressed(FrequentPlaceDetector.Reason)
        case noPlacesFound
        case suggested(PendingCheckin)
        case ignored
    }

    typealias PlacesLookup = @MainActor (_ coordinate: GeoCoordinate, _ radius: Double) async throws -> [Place]

    /// How far a search reaches around the visit. Core Location's accuracy for a
    /// visit is usually tens of meters, sometimes a few hundred.
    static let minimumSearchRadius: Double = 50
    static let maximumSearchRadius: Double = 250
    /// A second, wider try when nothing is listed right at the visit.
    static let fallbackSearchRadius: Double = 400
    static let maximumCandidatePlaces = 10

    private let visitHistory: VisitHistoryStore
    private let checkinStore: CheckinStore
    private let detector: FrequentPlaceDetector
    private let ranker = PlaceRanker()
    private let lookupPlaces: PlacesLookup
    private let calendar: Calendar
    private let logger = Logger(subsystem: "samgro.Hackysack", category: "VisitProcessor")

    init(
        visitHistory: VisitHistoryStore,
        checkinStore: CheckinStore,
        detector: FrequentPlaceDetector? = nil,
        calendar: Calendar = .current,
        lookupPlaces: @escaping PlacesLookup = { coordinate, radius in
            try await PlacesAPI().searchPlaces(
                latitude: coordinate.latitude,
                longitude: coordinate.longitude,
                radius: radius
            )
        }
    ) {
        self.visitHistory = visitHistory
        self.checkinStore = checkinStore
        self.detector = detector ?? FrequentPlaceDetector()
        self.calendar = calendar
        self.lookupPlaces = lookupPlaces
    }

    /// Entry point for Core Location deliveries. The work is wrapped in a
    /// background task so the Places request can finish when the delivery woke
    /// the app in the background.
    func process(_ visit: CLVisit) {
        let record = VisitRecord(visit: visit, receivedAt: Date())
        let taskIdentifier = UIApplication.shared.beginBackgroundTask(withName: "ProcessVisit")
        Task {
            let outcome = await process(record, now: Date())
            logger.info("Visit \(record.id, privacy: .public): \(String(describing: outcome), privacy: .public)")
            if taskIdentifier != .invalid {
                UIApplication.shared.endBackgroundTask(taskIdentifier)
            }
        }
    }

    @discardableResult
    func process(_ delivered: VisitRecord, now: Date) async -> Outcome {
        let result = visitHistory.record(delivered)
        let visit = result.record

        if !result.isNew {
            return applyRepeatDelivery(visit, now: now)
        }

        if let continuation = continuationOfRecentStay(for: visit) {
            return continuation
        }

        let assessment = detector.assess(
            visit: visit,
            history: visitHistory.visits,
            checkins: visitHistory.checkins,
            rejections: visitHistory.rejections,
            now: now,
            calendar: calendar
        )
        guard assessment.shouldSuggest else {
            return .suppressed(assessment.reason)
        }

        guard let places = await nearbyPlaces(for: visit), !places.isEmpty else {
            return .noPlacesFound
        }
        let suggestion = PendingCheckin(
            visit: visit,
            candidatePlaces: Array(ranked(places, for: visit).prefix(Self.maximumCandidatePlaces)),
            createdAt: now
        )
        checkinStore.add(suggestion: suggestion)
        return .suggested(suggestion)
    }

    /// The departure (or a duplicate arrival) for a visit already on file.
    private func applyRepeatDelivery(_ visit: VisitRecord, now: Date) -> Outcome {
        guard let suggestion = checkinStore.suggestion(forVisitId: visit.id) else {
            return .ignored
        }
        if visit.departureDate != nil,
           visit.duration(until: now) < detector.configuration.minimumCompletedVisitDuration {
            checkinStore.withdrawSuggestion(id: suggestion.id)
            return .withdrewSuggestion
        }
        checkinStore.updateSuggestionVisit(visit)
        return .updatedExistingSuggestion
    }

    /// Mirrors the detector's gap bridging at the suggestion level: coming back
    /// to a place less than two hours after leaving it is the same stay, so it
    /// extends the existing suggestion (or is already covered by a checkin the
    /// user made during the earlier part of the stay) instead of prompting again.
    private func continuationOfRecentStay(for visit: VisitRecord) -> Outcome? {
        let radius = detector.configuration.baseClusterRadiusMeters
        let maximumGap = detector.configuration.maximumGapToBridge
        let previousStay = visitHistory.visits
            .filter { candidate in
                candidate.id != visit.id
                    && candidate.coordinate.distance(to: visit.coordinate) <= radius
                    && candidate.arrivalDate < visit.arrivalDate
            }
            .compactMap { candidate -> (visit: VisitRecord, departure: Date)? in
                guard let departure = candidate.departureDate,
                      departure <= visit.arrivalDate,
                      visit.arrivalDate.timeIntervalSince(departure) < maximumGap else { return nil }
                return (candidate, departure)
            }
            .max { $0.departure < $1.departure }
        guard let previousStay else { return nil }

        if let suggestion = checkinStore.suggestion(forVisitId: previousStay.visit.id) {
            checkinStore.extendSuggestion(id: suggestion.id, with: visit)
            return .extendedSuggestion
        }

        let stayStart = previousStay.visit.arrivalDate.addingTimeInterval(-VisitHistoryStore.duplicateArrivalTolerance)
        let checkedInDuringStay = visitHistory.checkins.contains { checkin in
            checkin.date >= stayStart
                && checkin.date <= visit.arrivalDate
                && checkin.coordinate.distance(to: visit.coordinate) <= radius
        }
        return checkedInDuringStay ? .alreadyCheckedIn : nil
    }

    /// Orders the candidates the same way the manual checkin picker does, so
    /// the initial guess weighs distance, venue size and the user's history.
    /// Ranked as of the arrival, since that is when the user was there.
    private func ranked(_ places: [Place], for visit: VisitRecord) -> [Place] {
        let fix = LocationFix(
            latitude: visit.coordinate.latitude,
            longitude: visit.coordinate.longitude,
            horizontalAccuracy: visit.horizontalAccuracy,
            timestamp: visit.arrivalDate
        )
        return ranker.rank(
            candidates: places,
            fix: fix,
            history: checkinStore.checkinHistory,
            now: visit.arrivalDate,
            calendar: calendar
        )
        .ranked
        .map(\.place)
    }

    private func nearbyPlaces(for visit: VisitRecord) async -> [Place]? {
        let radius = min(max(visit.horizontalAccuracy, Self.minimumSearchRadius), Self.maximumSearchRadius)
        do {
            let places = try await lookupPlaces(visit.coordinate, radius)
            if !places.isEmpty {
                return places
            }
            return try await lookupPlaces(visit.coordinate, Self.fallbackSearchRadius)
        } catch {
            logger.error("Places lookup failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
