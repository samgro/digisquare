//
//  CheckinHistoryEntry.swift
//  Hackysack
//

import Foundation

/// One past checkin, reduced to what ranking needs. Decodable so the unit
/// tests can load sample histories from the shared fixtures. Foundation
/// only, like the ranker, so both compile outside the app; the conversion
/// from a `Checkin` lives in CheckinHistorySource.swift.
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
}
