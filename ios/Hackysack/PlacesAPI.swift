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
/// The venue's grounds, when Overture's base theme has a polygon for it (an
/// airport, a park, a campus). Rings are the polygon outlines, simplified to
/// a few meters; the bounding box is what the ranker sizes the venue by.
nonisolated struct PlaceExtent: Codable, Hashable, Sendable {
    struct BoundingBox: Codable, Hashable, Sendable {
        let south: Double
        let west: Double
        let north: Double
        let east: Double
    }

    let boundingBox: BoundingBox
    /// One outline per polygon, as longitude/latitude pairs.
    let rings: [[PlaceLocation]]
    let areaSquareMeters: Double

    private enum CodingKeys: String, CodingKey {
        case boundingBox, rings, areaSquareMeters
    }

    init(boundingBox: BoundingBox, rings: [[PlaceLocation]], areaSquareMeters: Double) {
        self.boundingBox = boundingBox
        self.rings = rings
        self.areaSquareMeters = areaSquareMeters
    }

    /// The API sends rings as GeoJSON positions, `[longitude, latitude]`.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        boundingBox = try container.decode(BoundingBox.self, forKey: .boundingBox)
        areaSquareMeters = try container.decode(Double.self, forKey: .areaSquareMeters)
        let positions = try container.decode([[[Double]]].self, forKey: .rings)
        rings = positions.map { ring in
            ring.compactMap { position in
                guard position.count >= 2 else { return nil }
                return PlaceLocation(latitude: position[1], longitude: position[0])
            }
        }
    }

    /// Written back in the same GeoJSON shape, so a place saved to disk with
    /// a pending suggestion decodes again.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(boundingBox, forKey: .boundingBox)
        try container.encode(areaSquareMeters, forKey: .areaSquareMeters)
        let positions = rings.map { ring in ring.map { [$0.longitude, $0.latitude] } }
        try container.encode(positions, forKey: .rings)
    }
}

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
    let extent: PlaceExtent?
    /// Meters from the searched fix to the venue's grounds (zero inside) or
    /// its pin, as the server measured it. Display only: the ranker measures
    /// against the latest fix itself.
    let distanceMeters: Double?
    /// Overture category codes, the primary one first.
    let types: [String]
    let primaryType: String?
    /// Checkins here from everyone. The app's stand-in for popularity.
    let checkinCount: Int
    /// Only its creator and their friends can find it.
    let isPrivate: Bool
    /// Dropped by a newer Overture release; only old checkins still show it.
    let retired: Bool
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
        extent: PlaceExtent? = nil,
        distanceMeters: Double? = nil,
        types: [String] = [],
        primaryType: String? = nil,
        checkinCount: Int = 0,
        isPrivate: Bool = false,
        retired: Bool = false,
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
        self.extent = extent
        self.distanceMeters = distanceMeters
        self.types = types
        self.primaryType = primaryType
        self.checkinCount = checkinCount
        self.isPrivate = isPrivate
        self.retired = retired
        self.website = website
        self.phone = phone
    }

    private enum CodingKeys: String, CodingKey {
        case id, source, name, address, street, locality, region, postcode, country
        case location, extent, distanceMeters, types, primaryType, checkinCount, isPrivate, retired, website, phone
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
        extent = try container.decodeIfPresent(PlaceExtent.self, forKey: .extent)
        distanceMeters = try container.decodeIfPresent(Double.self, forKey: .distanceMeters)
        types = try container.decodeIfPresent([String].self, forKey: .types) ?? []
        primaryType = try container.decodeIfPresent(String.self, forKey: .primaryType)
        checkinCount = try container.decodeIfPresent(Int.self, forKey: .checkinCount) ?? 0
        isPrivate = try container.decodeIfPresent(Bool.self, forKey: .isPrivate) ?? false
        retired = try container.decodeIfPresent(Bool.self, forKey: .retired) ?? false
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
