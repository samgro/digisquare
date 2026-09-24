//
//  CheckinsAPI.swift
//  Hackysack
//

import Foundation

/// Who can see a checkin: the owner's friends, or only the owner. Raw values
/// match the API; `onlyMe` avoids the `private` keyword.
enum CheckinVisibility: String, Codable, Equatable, CaseIterable {
    case friends
    case onlyMe = "private"

    var isPrivate: Bool { self == .onlyMe }

    mutating func toggle() {
        self = isPrivate ? .friends : .onlyMe
    }
}

/// Whether the user checked in by hand or accepted a suggestion from a detected visit.
enum CheckinSource: String, Codable, Equatable {
    case manual
    case visit
}

/// A checkin as returned by the API (`GET /checkins`, `POST /checkins`).
struct Checkin: Decodable, Identifiable, Equatable {
    let id: String
    let userId: String
    let googlePlaceId: String
    let placeName: String
    let placeAddress: String?
    let placePrimaryType: String?
    let placeTypes: [String]?
    let location: PlaceLocation?
    let message: String?
    let visibility: CheckinVisibility
    let source: CheckinSource
    let createdAt: Date
    let updatedAt: Date
}

/// The request body for `POST /checkins`. Coordinates are flat here but nested
/// under `location` in the response, so this is deliberately not derived from `Checkin`.
///
/// There is no userId: the server attributes the checkin to whoever the access
/// token identifies, and ignores one sent in the body.
struct CheckinDraft: Encodable, Equatable {
    let googlePlaceId: String
    let placeName: String
    let placeAddress: String?
    let placePrimaryType: String?
    let placeTypes: [String]?
    let latitude: Double?
    let longitude: Double?
    let message: String?
    let visibility: CheckinVisibility
    let source: CheckinSource
    /// Only sent for checkins accepted from a visit, so the server backdates
    /// them to the visit's arrival instead of the moment the user tapped Accept.
    let createdAt: Date?

    init(
        place: Place,
        message: String?,
        visibility: CheckinVisibility = .friends,
        source: CheckinSource = .manual,
        createdAt: Date? = nil
    ) {
        googlePlaceId = place.id
        placeName = place.name
        placeAddress = Self.trimmedOrNil(place.address)
        placePrimaryType = Self.trimmedOrNil(place.primaryType)
        placeTypes = place.types.isEmpty ? nil : place.types
        latitude = place.location?.latitude
        longitude = place.location?.longitude
        self.message = Self.trimmedOrNil(message)
        self.visibility = visibility
        self.source = source
        self.createdAt = createdAt
    }

    /// The API rejects empty strings for optional text fields, so they are omitted instead.
    private static func trimmedOrNil(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

private struct CheckinsResponse: Decodable {
    let results: [Checkin]
}

/// Every /checkins route requires a bearer token, so these go through
/// APIClient rather than URLSession directly — that is what attaches the
/// Authorization header and retries once through a token refresh on a 401.
///
/// APIClient also owns the JSONDecoder, including the fractional-seconds date
/// strategy these endpoints need: Hono serializes through toISOString(), which
/// always emits them, and the stock .iso8601 strategy rejects them.
struct CheckinsAPI {
    private let client: APIClient

    init(client: APIClient = .shared) {
        self.client = client
    }

    func createCheckin(_ draft: CheckinDraft) async throws -> Checkin {
        try await client.request(method: "POST", path: "checkins", body: draft)
    }

    func listCheckins(userId: String? = nil, limit: Int = 50, offset: Int = 0) async throws -> [Checkin] {
        var queryItems = [
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "offset", value: String(offset)),
        ]
        if let userId {
            queryItems.append(URLQueryItem(name: "userId", value: userId))
        }

        let response: CheckinsResponse = try await client.request(
            path: "checkins",
            queryItems: queryItems
        )
        return response.results
    }
}
