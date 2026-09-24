//
//  PlacesAPI.swift
//  Hackysack
//

import Foundation

/// Where a place row came from. Unknown values decode as `.overture` so a
/// newer API can add a source without breaking older builds.
nonisolated enum PlaceSource: String, Codable, Sendable {
    /// Imported from the Overture Maps places dataset.
    case overture
    /// Added by a user from the app.
    case user
    /// Carried over from a checkin made while the app used Google Places.
    case google

    init(from decoder: Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(String.self)
        self = PlaceSource(rawValue: rawValue) ?? .overture
    }
}

// These models are consumed by PlaceRanker, which is nonisolated so it can be
// exercised from unit tests and background work alike, so they opt out of the
// target's default @MainActor isolation the same way UserProfile does. They
// are Encodable too so pending suggestions can keep their candidate places on
// disk.
nonisolated struct Place: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let source: PlaceSource
    let name: String
    /// One line: "450 10th St, San Francisco, CA 94103, US", or `nil`.
    let address: String?
    /// The parts the line was built from, as Overture stores them: `region`
    /// is an ISO 3166-2 code such as "US-CA" and `country` a two-letter code.
    let street: String?
    let locality: String?
    let region: String?
    let postcode: String?
    let country: String?
    let location: PlaceLocation?
    /// Overture category codes, the primary one first.
    let types: [String]
    let primaryType: String?
    /// Checkins here from everyone. The app's stand-in for popularity.
    let checkinCount: Int
    let website: String?
    let phone: String?

    init(
        id: String,
        source: PlaceSource = .overture,
        name: String,
        address: String? = nil,
        street: String? = nil,
        locality: String? = nil,
        region: String? = nil,
        postcode: String? = nil,
        country: String? = nil,
        location: PlaceLocation?,
        types: [String] = [],
        primaryType: String? = nil,
        checkinCount: Int = 0,
        website: String? = nil,
        phone: String? = nil
    ) {
        self.id = id
        self.source = source
        self.name = name
        self.address = address
        self.street = street
        self.locality = locality
        self.region = region
        self.postcode = postcode
        self.country = country
        self.location = location
        self.types = types
        self.primaryType = primaryType
        self.checkinCount = checkinCount
        self.website = website
        self.phone = phone
    }

    private enum CodingKeys: String, CodingKey {
        case id, source, name, address, street, locality, region, postcode, country
        case location, types, primaryType, checkinCount, website, phone
    }

    /// Spelled out so the fields the API added over time (`source`,
    /// `checkinCount`) may be absent and the rest still decodes.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        source = try container.decodeIfPresent(PlaceSource.self, forKey: .source) ?? .overture
        name = try container.decode(String.self, forKey: .name)
        address = try container.decodeIfPresent(String.self, forKey: .address)
        street = try container.decodeIfPresent(String.self, forKey: .street)
        locality = try container.decodeIfPresent(String.self, forKey: .locality)
        region = try container.decodeIfPresent(String.self, forKey: .region)
        postcode = try container.decodeIfPresent(String.self, forKey: .postcode)
        country = try container.decodeIfPresent(String.self, forKey: .country)
        location = try container.decodeIfPresent(PlaceLocation.self, forKey: .location)
        types = try container.decodeIfPresent([String].self, forKey: .types) ?? []
        primaryType = try container.decodeIfPresent(String.self, forKey: .primaryType)
        checkinCount = try container.decodeIfPresent(Int.self, forKey: .checkinCount) ?? 0
        website = try container.decodeIfPresent(String.self, forKey: .website)
        phone = try container.decodeIfPresent(String.self, forKey: .phone)
    }
}

nonisolated struct PlaceLocation: Codable, Hashable, Sendable {
    let latitude: Double
    let longitude: Double
}

/// The request body for `POST /places`: a venue the user is adding by hand.
/// Only the name and the pin are required; the server validates the rest
/// (category codes, a two-letter country) and rejects empty strings, so
/// blank fields are sent as `nil`.
struct PlaceDraft: Encodable, Equatable {
    let name: String
    let primaryType: String?
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
            // Searching is open, and the checkin flow must keep working while
            // a token refresh is in flight.
            authenticated: false
        )
        return response.results
    }

    /// Adds a venue to the shared database. Needs a signed-in user, who is
    /// recorded as its creator.
    func createPlace(_ draft: PlaceDraft) async throws -> Place {
        try await client.request(method: "POST", path: "places", body: draft)
    }
}
