//
//  NotificationsAPI.swift
//  Hackysack
//

import Foundation

enum NotificationKind: String, Decodable, Equatable {
    case like
    case comment
    case friendRequest = "friend_request"
    case friendAccepted = "friend_accepted"
}

/// One row in the bell feed: who did what, and enough of the subject to say
/// so in a line and to open it.
struct AppNotification: Decodable, Identifiable, Equatable {
    /// The checkin a like or comment was on.
    struct CheckinReference: Decodable, Equatable {
        let id: String
        let placeName: String
    }

    struct CommentReference: Decodable, Equatable {
        let id: String
        let body: String
    }

    /// The request behind a friend notification. `pending` means Accept and
    /// Decline still apply.
    struct FriendshipReference: Decodable, Equatable {
        enum Status: String, Decodable, Equatable {
            case pending, accepted, declined
        }

        let id: String
        let status: Status
    }

    let id: String
    let kind: NotificationKind
    let actor: UserSummary
    let checkin: CheckinReference?
    let comment: CommentReference?
    let friendship: FriendshipReference?
    let readAt: Date?
    let createdAt: Date

    var isUnread: Bool { readAt == nil }

    /// What the actor did, to follow their name: "liked your checkin at Blue
    /// Bottle". Kept free of the name so the row can bold it separately.
    var summaryText: String {
        switch kind {
        case .like:
            return "liked your checkin\(placeSuffix)"
        case .comment:
            if let body = comment?.body {
                return "commented on your checkin\(placeSuffix): \u{201C}\(body)\u{201D}"
            }
            return "commented on your checkin\(placeSuffix)"
        case .friendRequest:
            return "wants to be friends"
        case .friendAccepted:
            return "accepted your friend request"
        }
    }

    private var placeSuffix: String {
        checkin.map { " at \($0.placeName)" } ?? ""
    }
}

struct NotificationsPage: Decodable {
    let results: [AppNotification]
    let unreadCount: Int
}

private struct UnreadCountResponse: Decodable {
    let unreadCount: Int
}

struct NotificationsAPI {
    private let client: APIClient

    init(client: APIClient = .shared) {
        self.client = client
    }

    /// Newest first. `before` is the createdAt of the last row already
    /// loaded, for the next page.
    func list(limit: Int = 30, before: Date? = nil) async throws -> NotificationsPage {
        try await client.request(
            path: "notifications",
            queryItems: ListPagination.queryItems(limit: limit, before: before)
        )
    }

    func unreadCount() async throws -> Int {
        let response: UnreadCountResponse = try await client.request(path: "notifications/unread-count")
        return response.unreadCount
    }

    func markAllRead() async throws {
        try await client.send(method: "POST", path: "notifications/read", body: Optional<EmptyRequestBody>.none)
    }
}
