//
//  FriendsStore.swift
//  Hackysack
//

import Foundation
import Observation

/// Friends and the Friends feed, shared by every screen that shows them, so
/// accepting a request or removing a friend in one place updates the feed
/// everywhere.
@Observable
@MainActor
final class FriendsStore {
    private(set) var friends: [PublicUser] = []
    private(set) var feed: [FriendCheckin] = []
    private(set) var hasLoadedFeed = false
    private(set) var feedError: String?

    @ObservationIgnored private let friendsAPI = FriendsAPI()

    // MARK: Loading

    func loadFeed() async {
        do {
            // Both are assigned together, so an empty feed is never shown
            // against a stale friends list or the other way round, which
            // would pick the wrong empty state.
            async let loadedFriends = friendsAPI.friends()
            async let loadedFeed = friendsAPI.friendCheckins()
            (friends, feed) = try await (loadedFriends, loadedFeed)
            feedError = nil
        } catch {
            feedError = error.localizedDescription
        }
        hasLoadedFeed = true
    }

    /// A like, comment or edit changed the checkin; the feed's copy follows.
    /// One edited to private leaves, as the server's feed leaves it out.
    func apply(_ checkin: Checkin) {
        guard let index = feed.firstIndex(where: { $0.id == checkin.id }) else { return }
        if checkin.visibility.isPrivate {
            feed.remove(at: index)
        } else {
            feed[index].checkin = checkin
        }
    }

    // MARK: Actions

    /// Returns where things stand afterwards. If they had already asked you,
    /// the server accepts their request and you are friends straight away.
    func sendRequest(to userId: String) async throws -> FriendshipState {
        let state = try await friendsAPI.sendRequest(to: userId)
        if state.status == .friends {
            await loadFeed()
        }
        return state
    }

    func accept(requestId: String) async throws {
        try await friendsAPI.accept(requestId: requestId)
        await loadFeed()
    }

    /// Declines a request you received, or cancels one you sent.
    func deleteRequest(requestId: String) async throws {
        try await friendsAPI.delete(requestId: requestId)
    }

    func removeFriend(userId: String) async throws {
        try await friendsAPI.removeFriend(userId: userId)
        friends.removeAll { $0.id == userId }
        feed.removeAll { $0.user.id == userId }
    }
}
