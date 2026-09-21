//
//  PlacesAPI.swift
//  Hackysack
//

import Foundation

// These models are consumed by PlaceRanker, which is nonisolated so it can be
// exercised from unit tests and background work alike, so they opt out of the
// target's default @MainActor isolation the same way UserProfile does. They
// are Encodable too so pending suggestions can keep their candidate places on
// disk.
nonisolated struct Place: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let address: String?
    let location: PlaceLocation?
    /// Google's bounding box for the place. Point venues get a default box a
    /// few hundred meters across; airports, campuses and parks get their real
    /// extent. Optional because older API builds do not send it.
    let viewport: PlaceViewport?
    let types: [String]
    let primaryType: String?
    let rating: Double?
    let userRatingCount: Int?

    /// Spelled out (rather than relying on the memberwise initializer) so the
    /// many existing call sites that predate `viewport` keep compiling.
    init(
        id: String,
        name: String,
        address: String?,
        location: PlaceLocation?,
        viewport: PlaceViewport? = nil,
        types: [String],
        primaryType: String?,
        rating: Double?,
        userRatingCount: Int?
    ) {
        self.id = id
        self.name = name
        self.address = address
        self.location = location
        self.viewport = viewport
        self.types = types
        self.primaryType = primaryType
        self.rating = rating
        self.userRatingCount = userRatingCount
    }
}

nonisolated struct PlaceLocation: Codable, Hashable, Sendable {
    let latitude: Double
    let longitude: Double
}

/// A latitude/longitude bounding box: `low` is the south-west corner and
/// `high` the north-east one, as Google reports them.
nonisolated struct PlaceViewport: Codable, Hashable, Sendable {
    let low: PlaceLocation
    let high: PlaceLocation
}

private struct PlacesResponse: Decodable {
    let results: [Place]
}

struct PlacesAPI {
    private let client: APIClient

    init(client: APIClient = .shared) {
        self.client = client
    }

    func searchPlaces(
        latitude: Double,
        longitude: Double,
        query: String? = nil,
        radius: Double? = nil,
        horizontalAccuracy: Double? = nil
    ) async throws -> [Place] {
        // The abbreviated names here are the API's query parameters, which is
        // the one place CLAUDE.md permits them. The Swift labels above are
        // spelled out.
        var queryItems = [
            URLQueryItem(name: "lat", value: String(latitude)),
            URLQueryItem(name: "lng", value: String(longitude)),
        ]
        if let query, !query.isEmpty {
            queryItems.append(URLQueryItem(name: "q", value: query))
        }
        if let radius, radius > 0 {
            queryItems.append(URLQueryItem(name: "radius", value: String(Int(radius.rounded()))))
        }
        // Core Location reports a negative accuracy when it has no estimate;
        // the server treats an absent value the same way.
        if let horizontalAccuracy, horizontalAccuracy >= 0 {
            queryItems.append(
                URLQueryItem(name: "accuracy", value: String(Int(horizontalAccuracy.rounded())))
            )
        }

        let response: PlacesResponse = try await client.request(
            path: "places",
            queryItems: queryItems,
            // /places is open, and the checkin flow must keep working while
            // a token refresh is in flight.
            authenticated: false
        )
        return response.results
    }
}
