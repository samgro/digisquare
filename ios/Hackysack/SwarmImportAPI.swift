//
//  SwarmImportAPI.swift
//  Hackysack
//

import Foundation

/// A run of the server's Swarm importer.
struct SwarmImport: Decodable, Identifiable, Equatable {
    enum Status: String, Decodable {
        case running
        case completed
        case failed
    }

    /// Checkins are imported first, then their photos are copied over.
    enum Phase: String, Decodable {
        case checkins
        case photos
    }

    let id: String
    let status: Status
    let phase: Phase
    /// Checkins this run has added so far.
    let checkinsImported: Int
    /// How many it should add in all, from Foursquare's count of the user's
    /// checkins. Nil until the server has asked, when progress is unknown.
    let checkinsExpected: Int?
    let photosTotal: Int
    let photosCopied: Int
    /// Written for people, safe to show as is.
    let error: String?
    let startedAt: Date
    let finishedAt: Date?

    /// How far along the run is, 0...1, or nil while the total is not known.
    /// A finished run reads as complete whatever its counts said.
    var progressFraction: Double? {
        if status == .completed {
            return 1
        }
        switch phase {
        case .checkins:
            guard let checkinsExpected, checkinsExpected > 0 else { return nil }
            return min(Double(checkinsImported) / Double(checkinsExpected), 1)
        case .photos:
            guard photosTotal > 0 else { return nil }
            return min(Double(photosCopied) / Double(photosTotal), 1)
        }
    }
}

struct SwarmImportState: Decodable, Equatable {
    let connected: Bool
    let latestImport: SwarmImport?
}

/// Connecting Swarm and importing its history. The import itself runs on the
/// server; the app starts it and watches its progress.
struct SwarmImportAPI {
    private struct AuthorizationResponse: Decodable {
        let authorizationUrl: URL
    }

    private let client: APIClient

    init(client: APIClient = .shared) {
        self.client = client
    }

    func state() async throws -> SwarmImportState {
        try await client.request(path: "imports/swarm")
    }

    /// Where to send the user to sign in to Foursquare. It comes back to the
    /// app on `SwarmImportAPI.callbackScheme` once the import has started.
    func authorizationURL() async throws -> URL {
        let response: AuthorizationResponse = try await client.request(
            method: "POST",
            path: "imports/swarm/authorization"
        )
        return response.authorizationUrl
    }

    /// Syncs again with the account already connected.
    func startSync() async throws -> SwarmImport {
        try await client.request(method: "POST", path: "imports/swarm")
    }

    func disconnect() async throws {
        try await client.send(method: "DELETE", path: "imports/swarm/connection", body: Optional<EmptyRequestBody>.none)
    }

    /// The server's OAuth callback redirects to hackysack://swarm-import.
    static let callbackScheme = "hackysack"
}
