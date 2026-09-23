//
//  PublicUser.swift
//  Hackysack
//

import Foundation

/// Display helpers shared by every kind of user model, so the signed-in
/// profile and other people's profiles render names the same way.
///
/// nonisolated because UserProfile, which crosses actors, uses `initials`.
nonisolated enum PersonName {
    /// Main actor-isolated because AppInfo is.
    @MainActor
    static func displayName(for name: String?) -> String {
        guard let name, !name.isEmpty else { return "\(AppInfo.name) member" }
        return name
    }

    static func initials(for name: String?) -> String {
        guard let name, !name.isEmpty else { return "?" }
        let words = name.split(separator: " ").prefix(2)
        let letters = words.compactMap { $0.first }.map(String.init)
        return letters.isEmpty ? "?" : letters.joined().uppercased()
    }
}

/// Just enough of someone to draw them in a row: what feed checkins carry,
/// and what a profile is opened with so its header can render before
/// the full profile has loaded.
struct UserSummary: Decodable, Identifiable, Hashable {
    let id: String
    let name: String?
    let avatarURL: URL?

    enum CodingKeys: String, CodingKey {
        case id, name
        case avatarURL = "avatarUrl"
    }

    var displayName: String { PersonName.displayName(for: name) }
    var initials: String { PersonName.initials(for: name) }
}

/// Somebody else's public profile (`GET /users/:id` without the extras, and
/// the requester on a friend request). Never carries an email.
struct PublicUser: Decodable, Identifiable, Hashable {
    let id: String
    let name: String?
    let bio: String?
    let avatarURL: URL?
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, name, bio
        case avatarURL = "avatarUrl"
        case createdAt
    }

    var displayName: String { PersonName.displayName(for: name) }
    var initials: String { PersonName.initials(for: name) }
    var summary: UserSummary { UserSummary(id: id, name: name, avatarURL: avatarURL) }
}

/// How the signed-in user relates to someone else, from their own side.
enum FriendshipStatus: String, Decodable {
    // Not `none`, which would read ambiguously next to Optional.none.
    case notFriends = "none"
    case friends
    case outgoingRequest
    case incomingRequest
}

/// The friendship fields the API adds to search results and profiles.
struct FriendshipState: Decodable, Equatable {
    var status: FriendshipStatus
    /// Set for a pending request in either direction, so it can be accepted,
    /// declined or cancelled.
    var friendRequestId: String?

    static let notFriends = FriendshipState(status: .notFriends, friendRequestId: nil)
    static let friends = FriendshipState(status: .friends, friendRequestId: nil)

    enum CodingKeys: String, CodingKey {
        case status = "friendshipStatus"
        case friendRequestId
    }
}

/// A row from `GET /users/search`: a public profile and the friendship
/// fields, flat on the wire.
struct UserSearchResult: Decodable, Identifiable, Equatable {
    let user: PublicUser
    var friendship: FriendshipState

    var id: String { user.id }

    init(from decoder: Decoder) throws {
        user = try PublicUser(from: decoder)
        friendship = try FriendshipState(from: decoder)
    }

    init(user: PublicUser, friendship: FriendshipState) {
        self.user = user
        self.friendship = friendship
    }
}

/// `GET /users/:id`. The checkin and friend counts are visible to anyone; the
/// checkins themselves are only listed for friends.
struct PublicProfile: Decodable, Equatable {
    let user: PublicUser
    let checkinCount: Int
    let friendCount: Int
    var friendship: FriendshipState

    enum CodingKeys: String, CodingKey {
        case checkinCount, friendCount
    }

    init(from decoder: Decoder) throws {
        user = try PublicUser(from: decoder)
        friendship = try FriendshipState(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        checkinCount = try container.decode(Int.self, forKey: .checkinCount)
        friendCount = try container.decode(Int.self, forKey: .friendCount)
    }

    init(user: PublicUser, checkinCount: Int, friendCount: Int, friendship: FriendshipState) {
        self.user = user
        self.checkinCount = checkinCount
        self.friendCount = friendCount
        self.friendship = friendship
    }
}

/// A pending request someone sent the signed-in user.
struct FriendRequest: Decodable, Identifiable, Equatable {
    let id: String
    let user: PublicUser
    let createdAt: Date
}

/// A row in the Friends feed: the usual checkin, flat on the wire, plus who
/// made it. Kept apart from Checkin so the timeline's model doesn't grow a
/// field it never has.
struct FriendCheckin: Decodable, Identifiable, Equatable {
    let checkin: Checkin
    let user: UserSummary

    var id: String { checkin.id }

    enum CodingKeys: String, CodingKey {
        case user
    }

    init(from decoder: Decoder) throws {
        checkin = try Checkin(from: decoder)
        user = try decoder.container(keyedBy: CodingKeys.self).decode(UserSummary.self, forKey: .user)
    }

    init(checkin: Checkin, user: UserSummary) {
        self.checkin = checkin
        self.user = user
    }
}
