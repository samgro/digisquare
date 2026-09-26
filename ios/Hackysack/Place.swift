//
//  Place.swift
//  Hackysack
//

import Foundation

// These models are consumed by PlaceRanker, which is nonisolated so it can be
// exercised from unit tests and background work alike, so they opt out of the
// target's default @MainActor isolation the same way UserProfile does. They
// are Encodable too so pending suggestions can keep their candidate places on
// disk. They depend on Foundation alone, so the ranker and everything it
// reads can be compiled outside the app (see api/scripts/ranking-evaluate).

/// Where a place row came from. Unknown values decode as `.overture` so a
/// newer API can add a source without breaking older builds.
nonisolated enum PlaceSource: String, Codable, Sendable {
    /// Imported from the Overture Maps places dataset.
    case overture
    /// Added by a user from the app.
    case user
    /// Carried over from a checkin made while the app used Google Places.
    case google
    /// The venue of a checkin imported from Swarm. Kept out of search until
    /// matched to Overture's copy of the same venue.
    case foursquare

    init(from decoder: Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(String.self)
        self = PlaceSource(rawValue: rawValue) ?? .overture
    }
}

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
    /// Overture's coarse category ("restaurant", "financial_service"), when known.
    let basicCategory: String?
    /// The source's own label for the primary category, when it has one: a
    /// Foursquare venue's "Hotpot Restaurant". Nil for Overture places, whose
    /// codes the app labels itself.
    let categoryName: String?
    /// Checkins here from everyone. The app's stand-in for popularity.
    let checkinCount: Int
    /// The server's log-odds that this is somewhere anyone checks in, from
    /// how trustworthy the record is (which provider it came from, whether
    /// others corroborate it) and its category: a restaurant is up, a
    /// mortgage lender down, a registry entry with no category far down.
    /// Zero when the server has no opinion. The ranker adds it to its score.
    let prior: Double
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
        basicCategory: String? = nil,
        categoryName: String? = nil,
        checkinCount: Int = 0,
        prior: Double = 0,
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
        self.basicCategory = basicCategory
        self.categoryName = categoryName
        self.checkinCount = checkinCount
        self.prior = prior
        self.isPrivate = isPrivate
        self.retired = retired
        self.website = website
        self.phone = phone
    }

    private enum CodingKeys: String, CodingKey {
        case id, source, name, address, street, locality, region, postcode, country
        case location, extent, distanceMeters, types, primaryType, basicCategory, categoryName
        case checkinCount, prior, isPrivate, retired
        case website, phone
    }

    /// Spelled out so the fields the API added over time (`source`,
    /// `checkinCount`, `prior`) may be absent and the rest still decodes.
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
        basicCategory = try container.decodeIfPresent(String.self, forKey: .basicCategory)
        categoryName = try container.decodeIfPresent(String.self, forKey: .categoryName)
        checkinCount = try container.decodeIfPresent(Int.self, forKey: .checkinCount) ?? 0
        prior = try container.decodeIfPresent(Double.self, forKey: .prior) ?? 0
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
