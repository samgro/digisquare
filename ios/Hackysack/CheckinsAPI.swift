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
    let location: PlaceLocation?
    let message: String?
    let visibility: CheckinVisibility
    let source: CheckinSource
    // The API always sends these; the defaults are for placeholders built
    // locally, which nobody has had a chance to like yet.
    var likeCount = 0
    var commentCount = 0
    var likedByMe = false
    let createdAt: Date
    let updatedAt: Date
}

/// The request body for `POST /checkins`: just the place's id and a message.
/// The server snapshots the place's name, address and category from its own
/// `places` row, so nothing the client says about the place is trusted.
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

    private enum CodingKeys: String, CodingKey {
        case placeId, message, visibility, source, createdAt
    }

    init(
        place: Place,
        message: String?,
        visibility: CheckinVisibility = .friends,
        source: CheckinSource = .manual,
        createdAt: Date? = nil
    ) {
        self.place = place
        placeId = place.id
        self.message = Self.trimmedOrNil(message)
        self.visibility = visibility
        self.source = source
        self.createdAt = createdAt
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

    func checkin(id: String) async throws -> Checkin {
        try await client.request(path: "checkins/\(id)")
    }

    func updateCheckin(id: String, _ update: CheckinUpdate) async throws -> Checkin {
        try await client.request(method: "PATCH", path: "checkins/\(id)", body: update)
    }

    /// Newest first. `before` is the createdAt of the last row already
    /// loaded, for the next page.
    func listCheckins(userId: String? = nil, limit: Int = 50, before: Date? = nil) async throws -> [Checkin] {
        var queryItems = ListPagination.queryItems(limit: limit, before: before)
        if let userId {
            queryItems.append(URLQueryItem(name: "userId", value: userId))
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
