//
//  FriendsAPI.swift
//  Hackysack
//

import Foundation

private struct SendFriendRequestBody: Encodable {
    let userId: String
}

private struct FriendRequestResponse: Decodable {
    let id: String
    let status: String
}

/// People search, friend requests and the friends feed. Every route needs a
/// bearer token, so these go through APIClient like CheckinsAPI does.
struct FriendsAPI {
    private let client: APIClient

    init(client: APIClient = .shared) {
        self.client = client
    }

    // MARK: People

    func searchUsers(query: String) async throws -> [UserSearchResult] {
        let response: ResultsResponse<UserSearchResult> = try await client.request(
            path: "users/search",
            queryItems: [URLQueryItem(name: "q", value: query)]
        )
        return response.results
    }

    func profile(userId: String) async throws -> PublicProfile {
        try await client.request(path: "users/\(userId)")
    }

    // MARK: Friends

    func friends() async throws -> [PublicUser] {
        let response: ResultsResponse<PublicUser> = try await client.request(path: "friends")
        return response.results
    }

    /// Newest first. `before` is the createdAt of the last row already
    /// loaded, for the next page.
    func friendCheckins(limit: Int = 50, before: Date? = nil) async throws -> [FriendCheckin] {
        let response: ResultsResponse<FriendCheckin> = try await client.request(
            path: "friends/checkins",
            queryItems: ListPagination.queryItems(limit: limit, before: before)
        )
        return response.results
    }

    func removeFriend(userId: String) async throws {
        try await client.send(method: "DELETE", path: "friends/\(userId)", body: Optional<EmptyRequestBody>.none)
    }

    // MARK: Requests

    func incomingRequests() async throws -> [FriendRequest] {
        let response: ResultsResponse<FriendRequest> = try await client.request(path: "friends/requests")
        return response.results
    }

    /// Returns where things stand afterwards: a pending outgoing request, or
    /// friends already if they had asked first (the server accepts theirs).
    func sendRequest(to userId: String) async throws -> FriendshipState {
        let response: FriendRequestResponse = try await client.request(
            method: "POST",
            path: "friends/requests",
            body: SendFriendRequestBody(userId: userId)
        )
        if response.status == "accepted" {
            return .friends
        }
        return FriendshipState(status: .outgoingRequest, friendRequestId: response.id)
    }

    func accept(requestId: String) async throws {
        let _: EmptyResponse = try await client.request(
            method: "POST",
            path: "friends/requests/\(requestId)/accept"
        )
    }

    /// Declines a request you received, or cancels one you sent. A declined
    /// request still looks pending to its sender; a cancelled one is deleted.
    func delete(requestId: String) async throws {
        try await client.send(method: "DELETE", path: "friends/requests/\(requestId)", body: Optional<EmptyRequestBody>.none)
    }
}
