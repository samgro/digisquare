//
//  PlacesAPI.swift
//  Hackysack
//

import Foundation

/// The request body for `POST /places`: a venue the user is adding by hand.
/// Only the name and the pin are required; the server validates the rest
/// (category codes, a two-letter country) and rejects empty strings, so
/// blank fields are sent as `nil`.
struct PlaceDraft: Encodable, Equatable {
    let name: String
    let primaryType: String?
    /// Only the creator and their friends can find a private venue.
    let isPrivate: Bool
    let street: String?
    let locality: String?
    let region: String?
    let postcode: String?
    let country: String?
    let latitude: Double
    let longitude: Double
    let website: String?
    let phone: String?

    init(
        name: String,
        primaryType: String?,
        isPrivate: Bool,
        street: String?,
        locality: String?,
        region: String?,
        postcode: String?,
        country: String?,
        latitude: Double,
        longitude: Double,
        website: String?,
        phone: String?
    ) {
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.primaryType = primaryType
        self.isPrivate = isPrivate
        self.street = Self.trimmedOrNil(street)
        self.locality = Self.trimmedOrNil(locality)
        self.region = Self.trimmedOrNil(region)
        self.postcode = Self.trimmedOrNil(postcode)
        self.country = Self.trimmedOrNil(country)?.uppercased()
        self.latitude = latitude
        self.longitude = longitude
        self.website = Self.trimmedOrNil(website)
        self.phone = Self.trimmedOrNil(phone)
    }

    private static func trimmedOrNil(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

/// Whether the server holds place data around the searched fix. When it does
/// not, the API is fetching it in the background (`importing`) or could not
/// (`missing`, `failed`), and the app tells the user when to try again.
nonisolated struct PlaceCoverage: Decodable, Hashable, Sendable {
    enum Status: String, Decodable, Sendable {
        case ready, importing, missing, failed

        /// Unknown values from a newer API read as ready, which shows whatever
        /// results came back rather than an alarming empty state.
        init(from decoder: Decoder) throws {
            let rawValue = try decoder.singleValueContainer().decode(String.self)
            self = Status(rawValue: rawValue) ?? .ready
        }
    }

    let status: Status
    /// Present while importing: how long until the data should be there.
    /// A `missing` report carries no timing on purpose: the server never
    /// says how long its limits last.
    let estimatedSecondsRemaining: Double?

    static let ready = PlaceCoverage(status: .ready, estimatedSecondsRemaining: nil)

    init(status: Status, estimatedSecondsRemaining: Double?) {
        self.status = status
        self.estimatedSecondsRemaining = estimatedSecondsRemaining
    }

    private enum CodingKeys: String, CodingKey {
        case status, estimatedSecondsRemaining
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try container.decodeIfPresent(Status.self, forKey: .status) ?? .ready
        estimatedSecondsRemaining = try container.decodeIfPresent(Double.self, forKey: .estimatedSecondsRemaining)
    }

    /// "a minute", "3 minutes": the wait rounded up, never promising under a minute.
    var waitDescription: String? {
        guard let seconds = estimatedSecondsRemaining else { return nil }
        let minutes = max(1, Int((seconds / 60).rounded(.up)))
        return minutes == 1 ? "a minute" : "\(minutes) minutes"
    }
}

nonisolated struct PlaceSearchResult: Decodable, Sendable {
    let results: [Place]
    let coverage: PlaceCoverage

    private enum CodingKeys: String, CodingKey {
        case results, coverage
    }

    init(results: [Place], coverage: PlaceCoverage) {
        self.results = results
        self.coverage = coverage
    }

    /// `coverage` is absent from an older API build; that reads as ready.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        results = try container.decode([Place].self, forKey: .results)
        coverage = try container.decodeIfPresent(PlaceCoverage.self, forKey: .coverage) ?? .ready
    }
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
        horizontalAccuracy: Double? = nil,
        passive: Bool = false
    ) async throws -> PlaceSearchResult {
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

        // A passive lookup reports coverage but never starts a fetch: for
        // lookups nobody is waiting on, which should not spend the user's
        // daily area fetches.
        if passive {
            queryItems.append(URLQueryItem(name: "passive", value: "1"))
        }

        // Sent with the token: the server includes the user's private venues
        // and may start fetching an uncovered area for them. A stale token gets
        // a 401, which APIClient answers by refreshing and retrying once, so a
        // refresh in flight never blocks the checkin flow.
        return try await client.request(path: "places", queryItems: queryItems)
    }

    /// Adds a venue to the shared database. Needs a signed-in user, who is
    /// recorded as its creator.
    func createPlace(_ draft: PlaceDraft) async throws -> Place {
        try await client.request(method: "POST", path: "places", body: draft)
    }
}
