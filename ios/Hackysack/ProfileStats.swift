//
//  ProfileStats.swift
//  Hackysack
//

import Foundation

/// The numbers on a profile, from `GET /users/:id/stats`.
///
/// Counted by the server rather than from CheckinStore: the device only holds
/// one page of checkins, so anyone past it would be undercounted.
nonisolated struct ProfileStats: Decodable, Equatable, Sendable {
    nonisolated struct TopPlace: Decodable, Equatable, Identifiable, Sendable {
        let googlePlaceId: String
        /// From the latest checkin there, so a renamed venue shows its
        /// current name.
        let placeName: String
        let placePrimaryType: String?
        let checkinCount: Int

        var id: String { googlePlaceId }
    }

    let checkinCount: Int
    /// Distinct places checked in to.
    let placeCount: Int
    /// Most visited first, at most three.
    let topPlaces: [TopPlace]

    static func load(userId: String) async throws -> ProfileStats {
        try await APIClient.shared.request(path: "users/\(userId)/stats")
    }
}
