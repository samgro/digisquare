//
//  CheckinHistorySource.swift
//  Hackysack
//

import Foundation

/// One past checkin, reduced to what ranking needs. Decodable so the unit
/// tests can load sample histories from the shared fixtures.
nonisolated struct CheckinHistoryEntry: Decodable, Hashable, Sendable {
    let placeId: String
    let createdAt: Date
    let placeName: String
    let placeAddress: String?
    let placePrimaryType: String?
    let placeTypes: [String]
    let location: PlaceLocation?

    init(
        placeId: String,
        createdAt: Date,
        placeName: String,
        placeAddress: String? = nil,
        placePrimaryType: String? = nil,
        placeTypes: [String] = [],
        location: PlaceLocation? = nil
    ) {
        self.placeId = placeId
        self.createdAt = createdAt
        self.placeName = placeName
        self.placeAddress = placeAddress
        self.placePrimaryType = placePrimaryType
        self.placeTypes = placeTypes
        self.location = location
    }

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

extension CheckinHistoryEntry {
    /// Straight from the stored columns, skipping the full `Checkin` a
    /// record would otherwise build, since a history can run to thousands.
    @MainActor
    init(record: CheckinRecord) {
        var location: PlaceLocation?
        if let latitude = record.latitude, let longitude = record.longitude {
            location = PlaceLocation(latitude: latitude, longitude: longitude)
        }
        self.init(
            placeId: record.placeId,
            createdAt: record.createdAt,
            placeName: record.placeName,
            placeAddress: record.placeAddress,
            placePrimaryType: record.placePrimaryType,
            placeTypes: record.placeTypes ?? [],
            location: location
        )
    }
}

/// Where the checkin picker gets the user's past checkins from: every
/// checkin in the local database, plus anything still saving.
@MainActor
protocol CheckinHistorySource {
    var checkinHistory: [CheckinHistoryEntry] { get }
}

extension CheckinStore: CheckinHistorySource {
    var checkinHistory: [CheckinHistoryEntry] {
        // Suggestions are left out: the user hasn't said they were there yet.
        // A saved checkin can sit in both places until the database takes it.
        let pending = pendingEntries
            .filter { historySync?.isStored($0.checkin.id) != true }
            .map { CheckinHistoryEntry(checkin: $0.checkin) }
        return pending + (historySync?.historyEntries ?? [])
    }
}
