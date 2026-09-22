//
//  FriendsStore.swift
//  Hackysack
//

import Foundation
import Observation

/// Friends, incoming friend requests and the Friends feed, shared by every
/// screen that shows them. Holding them in one place is what keeps the Profile
/// tab badge, the requests modal and the feed in step: accepting a request in
/// one updates the other two.
@Observable
@MainActor
final class FriendsStore {
    private(set) var incomingRequests: [FriendRequest] = []
    private(set) var friends: [PublicUser] = []
    private(set) var feed: [FriendCheckin] = []
    private(set) var hasLoadedFeed = false
    private(set) var feedError: String?

    @ObservationIgnored private let friendsAPI = FriendsAPI()

    var pendingRequestCount: Int { incomingRequests.count }

    // MARK: Loading

    /// Drives the Profile tab badge, so a failure keeps whatever was last
    /// loaded rather than clearing a badge the user may be about to act on.
    func loadRequests() async {
        do {
            incomingRequests = try await friendsAPI.incomingRequests()
        } catch {
            DevLog.network("Couldn't load friend requests: \(error)")
        }
    }

    func loadFeed() async {
        do {
            // Both are assigned together, so an empty feed is never shown
            // against a stale friends list or the other way round, which
            // would pick the wrong empty state.
            let loadedFriends = try await friendsAPI.friends()
            let loadedFeed = try await friendsAPI.friendCheckins()
            friends = loadedFriends
            feed = loadedFeed
            feedError = nil
        } catch {
            feedError = error.localizedDescription
        }
        hasLoadedFeed = true
    }

    // MARK: Actions

    /// Returns where things stand afterwards. If they had already asked you,
    /// the server accepts their request and you are friends straight away.
    func sendRequest(to userId: String) async throws -> FriendshipState {
        let state = try await friendsAPI.sendRequest(to: userId)
        if state.status == .friends {
            incomingRequests.removeAll { $0.user.id == userId }
            await loadFeed()
        }
        return state
    }

    func accept(requestId: String) async throws {
        try await friendsAPI.accept(requestId: requestId)
        incomingRequests.removeAll { $0.id == requestId }
        await loadFeed()
    }

    /// Declines a request you received, or cancels one you sent.
    func deleteRequest(requestId: String) async throws {
        try await friendsAPI.delete(requestId: requestId)
        incomingRequests.removeAll { $0.id == requestId }
    }

    func removeFriend(userId: String) async throws {
        try await friendsAPI.removeFriend(userId: userId)
        friends.removeAll { $0.id == userId }
        feed.removeAll { $0.user.id == userId }
    }
}
