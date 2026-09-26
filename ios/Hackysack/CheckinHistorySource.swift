//
//  CheckinHistorySource.swift
//  Hackysack
//

import Foundation

extension CheckinHistoryEntry {
    @MainActor
    init(checkin: Checkin) {
        self.init(
            placeId: checkin.placeId,
            createdAt: checkin.createdAt,
            placeName: checkin.placeName,
            placeAddress: checkin.placeAddress,
            placePrimaryType: checkin.placePrimaryType,
            placeTypes: checkin.placeTypes ?? [],
            location: checkin.location
        )
    }
}

/// Where the checkin picker gets the user's past checkins from.
///
/// Today that is the in-memory timeline (the most recent 50 saved on the
/// server, plus anything still saving). A local store of every checkin can
/// replace this conformance without touching the picker or the ranker.
@MainActor
protocol CheckinHistorySource {
    var checkinHistory: [CheckinHistoryEntry] { get }
}

extension CheckinStore: CheckinHistorySource {
    var checkinHistory: [CheckinHistoryEntry] {
        // Suggestions are left out: the user hasn't said they were there yet.
        savedEntries.map { CheckinHistoryEntry(checkin: $0.checkin) }
    }
}
