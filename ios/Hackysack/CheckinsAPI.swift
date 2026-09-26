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

/// Whether the user checked in by hand, accepted a suggestion from a detected
/// visit, or imported the checkin from Swarm. Unknown values from a newer API
/// read as manual, the plainest kind.
enum CheckinSource: String, Codable, Equatable {
    case manual
    case visit
    case swarm

    init(from decoder: Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(String.self)
        self = CheckinSource(rawValue: rawValue) ?? .manual
    }
}

/// A photo on a checkin, served from wherever the server says: R2 for photos
/// taken here and copied Swarm photos, Foursquare for ones not yet copied.
struct CheckinPhoto: Decodable, Identifiable, Hashable {
    let id: String
    let url: URL
    let width: Int?
    let height: Int?
}

/// A checkin as returned by the API (`GET /checkins`, `POST /checkins`).
///
/// Hashable so it can be the item behind a navigation destination.
struct Checkin: Decodable, Identifiable, Hashable {
    let id: String
    let userId: String
    let placeId: String
    /// A snapshot of the place as it was at checkin time, so the row reads
    /// the same even after the venue is renamed or re-imported.
    let placeName: String
    let placeAddress: String?
    /// Absent on rows saved before the API stored it separately.
    let placeLocality: String?
    let placePrimaryType: String?
    let placeTypes: [String]?
    /// The place's own label for its category, such as Foursquare's "Hotpot
    /// Restaurant", when the source gave one. Nil for Overture places, whose
    /// codes the app labels itself.
    let placeCategoryName: String?
    let location: PlaceLocation?
    let message: String?
    let visibility: CheckinVisibility
    let source: CheckinSource
    var photos: [CheckinPhoto] = []
    /// Minutes east of UTC where the checkin happened, so it can be shown in
    /// that place's local time. Nil for checkins from before this was sent.
    let timeZoneOffsetMinutes: Int?
    // The API always sends these; the defaults are for placeholders built
    // locally, which nobody has had a chance to like yet.
    var likeCount = 0
    var commentCount = 0
    var likedByMe = false
    let createdAt: Date
    let updatedAt: Date
}

extension Checkin {
    private enum CodingKeys: String, CodingKey {
        case id, userId, placeId, placeName, placeAddress, placeLocality, placePrimaryType, placeTypes
        case placeCategoryName, location, message, visibility, source, photos, timeZoneOffsetMinutes
        case likeCount, commentCount, likedByMe, createdAt, updatedAt
    }

    /// Spelled out, in an extension so the memberwise initializer survives,
    /// so the fields the API added over time may be absent and the rest still
    /// decodes.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        userId = try container.decode(String.self, forKey: .userId)
        placeId = try container.decode(String.self, forKey: .placeId)
        placeName = try container.decode(String.self, forKey: .placeName)
        placeAddress = try container.decodeIfPresent(String.self, forKey: .placeAddress)
        placeLocality = try container.decodeIfPresent(String.self, forKey: .placeLocality)
        placePrimaryType = try container.decodeIfPresent(String.self, forKey: .placePrimaryType)
        placeTypes = try container.decodeIfPresent([String].self, forKey: .placeTypes)
        placeCategoryName = try container.decodeIfPresent(String.self, forKey: .placeCategoryName)
        location = try container.decodeIfPresent(PlaceLocation.self, forKey: .location)
        message = try container.decodeIfPresent(String.self, forKey: .message)
        visibility = try container.decodeIfPresent(CheckinVisibility.self, forKey: .visibility) ?? .friends
        source = try container.decodeIfPresent(CheckinSource.self, forKey: .source) ?? .manual
        photos = try container.decodeIfPresent([CheckinPhoto].self, forKey: .photos) ?? []
        timeZoneOffsetMinutes = try container.decodeIfPresent(Int.self, forKey: .timeZoneOffsetMinutes)
        likeCount = try container.decodeIfPresent(Int.self, forKey: .likeCount) ?? 0
        commentCount = try container.decodeIfPresent(Int.self, forKey: .commentCount) ?? 0
        likedByMe = try container.decodeIfPresent(Bool.self, forKey: .likedByMe) ?? false
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }
}

/// A photo already uploaded to storage, ready to attach to a new checkin.
struct UploadedCheckinPhoto: Encodable, Equatable {
    let key: String
    let width: Int
    let height: Int
}

/// The request body for `POST /checkins`: the place's id, a message, and the
/// photos already uploaded for it. The server snapshots the place's name,
/// address and category from its own `places` row, so nothing the client says
/// about the place is trusted.
///
/// There is no userId: the server attributes the checkin to whoever the access
/// token identifies, and ignores one sent in the body.
///
/// The `place` itself is kept (but never sent) so the timeline can show a
/// placeholder row while the save is in flight.
struct CheckinDraft: Encodable, Equatable {
    let place: Place
    let placeId: String
    let message: String?
    let visibility: CheckinVisibility
    let source: CheckinSource
    /// Only sent for checkins accepted from a visit, so the server backdates
    /// them to the visit's arrival instead of the moment the user tapped Accept.
    let createdAt: Date?
    /// Where the user is, so the checkin can be shown in local time wherever
    /// it is read later.
    let timeZoneOffsetMinutes: Int
    /// Filled in once the photos have uploaded, just before the checkin is sent.
    var photos: [UploadedCheckinPhoto] = []

    private enum CodingKeys: String, CodingKey {
        case placeId, message, visibility, source, createdAt, timeZoneOffsetMinutes, photos
    }

    init(
        place: Place,
        message: String?,
        visibility: CheckinVisibility = .friends,
        source: CheckinSource = .manual,
        createdAt: Date? = nil,
        timeZone: TimeZone = .current
    ) {
        self.place = place
        placeId = place.id
        self.message = Self.trimmedOrNil(message)
        self.visibility = visibility
        self.source = source
        self.createdAt = createdAt
        timeZoneOffsetMinutes = timeZone.secondsFromGMT(for: createdAt ?? Date()) / 60
    }

    /// The API rejects empty strings for optional text fields, so they are omitted instead.
    static func trimmedOrNil(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

/// The body for `PATCH /checkins/:id`: the two things that can change after
/// checking in. The venue is fixed.
///
/// `message` is always written, as JSON null when empty: the API reads a
/// missing key as "leave it" and null as "clear it".
struct CheckinUpdate: Encodable, Equatable {
    let message: String?
    let visibility: CheckinVisibility

    init(message: String?, visibility: CheckinVisibility) {
        self.message = CheckinDraft.trimmedOrNil(message)
        self.visibility = visibility
    }

    enum CodingKeys: String, CodingKey {
        case message, visibility
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(message, forKey: .message)
        try container.encode(visibility, forKey: .visibility)
    }
}

/// What `POST` and `DELETE /checkins/:id/likes` answer with.
struct CheckinLikeState: Decodable, Equatable {
    let likeCount: Int
    let likedByMe: Bool
}

/// A comment on a checkin, with just enough of its author to draw the row.
struct CheckinComment: Decodable, Identifiable, Equatable {
    let id: String
    let checkinId: String
    let body: String
    let createdAt: Date
    let user: UserSummary
}

private struct CommentBody: Encodable {
    let body: String
}

/// A presigned URL to PUT one JPEG to, and the key to hand back afterwards.
struct ImageUpload: Decodable {
    let uploadUrl: URL
    let key: String
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

    /// Uploads one photo for a checkin that has not been created yet.
    func uploadPhoto(_ photo: PreparedPhoto) async throws -> UploadedCheckinPhoto {
        let key = try await client.uploadJPEG(photo.jpegData, uploadPath: "checkins/photo-uploads")
        return UploadedCheckinPhoto(key: key, width: photo.width, height: photo.height)
    }

    func checkin(id: String) async throws -> Checkin {
        try await client.request(path: "checkins/\(id)")
    }

    func updateCheckin(id: String, _ update: CheckinUpdate) async throws -> Checkin {
        try await client.request(method: "PATCH", path: "checkins/\(id)", body: update)
    }

    /// Newest first. `before` is the createdAt of the last row already
    /// loaded, for the next page.
    func listCheckins(
        userId: String? = nil,
        placeId: String? = nil,
        limit: Int = CheckinPaging.pageSize,
        before: Date? = nil
    ) async throws -> [Checkin] {
        var queryItems = ListPagination.queryItems(limit: limit, before: before)
        if let userId {
            queryItems.append(URLQueryItem(name: "userId", value: userId))
        }
        if let placeId {
            queryItems.append(URLQueryItem(name: "placeId", value: placeId))
        }

        let response: ResultsResponse<Checkin> = try await client.request(
            path: "checkins",
            queryItems: queryItems
        )
        return response.results
    }

    // MARK: Likes

    func like(checkinId: String) async throws -> CheckinLikeState {
        try await client.request(method: "POST", path: "checkins/\(checkinId)/likes")
    }

    func unlike(checkinId: String) async throws -> CheckinLikeState {
        try await client.request(method: "DELETE", path: "checkins/\(checkinId)/likes")
    }

    // MARK: Comments

    /// Newest first, like every list; callers reverse it to read a thread top down.
    func comments(checkinId: String, limit: Int = 50, before: Date? = nil) async throws -> [CheckinComment] {
        let response: ResultsResponse<CheckinComment> = try await client.request(
            path: "checkins/\(checkinId)/comments",
            queryItems: ListPagination.queryItems(limit: limit, before: before)
        )
        return response.results
    }

    func addComment(checkinId: String, body: String) async throws -> CheckinComment {
        try await client.request(
            method: "POST",
            path: "checkins/\(checkinId)/comments",
            body: CommentBody(body: body)
        )
    }

    func deleteComment(checkinId: String, commentId: String) async throws {
        try await client.send(
            method: "DELETE",
            path: "checkins/\(checkinId)/comments/\(commentId)",
            body: Optional<EmptyRequestBody>.none
        )
    }
}
