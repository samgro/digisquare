//
//  AuthSessionStore.swift
//  Hackysack
//

import Foundation

enum SignOutReason: Sendable {
    case userInitiated
    /// The server rejected our refresh token — it is spent or revoked.
    case refreshRejected
}

/// Owns the tokens and serializes refreshes.
///
/// This is an explicit `actor`, and must stay one. The target builds with
/// SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor, so an unannotated class here
/// would silently become @MainActor and lose the serialization this type
/// exists to provide. Do not "simplify" it into a final class.
actor AuthSessionStore {
    /// The Keychain account of the server these tokens belong to.
    private let keychainAccount: String
    private var credentials: StoredCredentials?
    private var refreshTask: Task<StoredCredentials, any Error>?

    /// Called whenever the stored credentials change, so AuthManager can
    /// update the UI. Hopped to the main actor by the closure itself.
    private let onCredentialsChanged: @Sendable (StoredCredentials?) async -> Void

    init(
        keychainAccount: String,
        credentials: StoredCredentials?,
        onCredentialsChanged: @escaping @Sendable (StoredCredentials?) async -> Void
    ) {
        self.keychainAccount = keychainAccount
        self.credentials = credentials
        self.onCredentialsChanged = onCredentialsChanged
    }

    // MARK: - Reads

    func currentAccessToken() -> String? {
        credentials?.accessToken
    }

    func currentCredentials() -> StoredCredentials? {
        credentials
    }

    // MARK: - Writes

    func adopt(_ credentials: StoredCredentials) async {
        self.credentials = credentials
        try? KeychainStore.save(credentials, account: keychainAccount)
        await onCredentialsChanged(credentials)
    }

    /// Seeds the in-memory copy from a Keychain read the caller already did,
    /// without writing back or notifying. Only for the locked-at-launch retry;
    /// a normal launch passes the credentials to `init` instead.
    func seed(_ credentials: StoredCredentials?) {
        self.credentials = credentials
    }

    func updateProfile(_ profile: UserProfile) async {
        guard var updated = credentials else { return }
        updated.profile = profile
        await adopt(updated)
    }

    func signOut(reason: SignOutReason) async {
        credentials = nil
        refreshTask = nil
        try? KeychainStore.delete(account: keychainAccount)
        await onCredentialsChanged(nil)
    }

    // MARK: - Refresh

    /// Returns credentials newer than the access token the caller used.
    ///
    /// Callers reach here when a request came back 401. Several requests can
    /// do that at once, and each duplicate refresh would send an
    /// already-rotated token — which the server reads as replay and answers by
    /// revoking the whole family, signing the user out. Two guards prevent
    /// that, and both are needed:
    ///
    ///  1. The staleness check below catches requests that 401 in a stagger,
    ///     arriving after a refresh has already finished.
    ///  2. The in-flight join catches requests that 401 simultaneously.
    ///
    /// Either one alone still leaves a path to a second refresh.
    func refreshedCredentials(replacing staleAccessToken: String) async throws -> StoredCredentials {
        // 1. Somebody already refreshed while this request was in flight.
        if let credentials, credentials.accessToken != staleAccessToken {
            return credentials
        }

        // 2. A refresh is already running — join it rather than starting a second.
        if let refreshTask {
            return try await refreshTask.value
        }

        guard let refreshToken = credentials?.refreshToken else {
            throw APIError.unauthorized
        }
        let existingProfile = credentials?.profile

        let task = Task<StoredCredentials, any Error> {
            try await Self.performRefresh(
                refreshToken: refreshToken,
                existingProfile: existingProfile
            )
        }
        refreshTask = task

        defer { refreshTask = nil }

        let refreshed = try await task.value
        // Persist before returning, so a crash between here and the next
        // request cannot strand us holding a token the server has rotated.
        try? KeychainStore.save(refreshed, account: keychainAccount)
        credentials = refreshed
        await onCredentialsChanged(refreshed)
        return refreshed
    }

    private static func performRefresh(
        refreshToken: String,
        existingProfile: UserProfile?
    ) async throws -> StoredCredentials {
        struct RefreshRequest: Encodable {
            let refreshToken: String
        }

        let response: RefreshResponse = try await APIClient.shared.request(
            method: "POST",
            path: "auth/refresh",
            body: RefreshRequest(refreshToken: refreshToken),
            // Must not be authenticated: the access token is expired, and
            // attaching it would recurse straight back into this method.
            authenticated: false
        )

        guard let existingProfile else {
            throw APIError.unauthorized
        }

        return StoredCredentials(
            accessToken: response.accessToken,
            accessTokenExpiresAt: Date().addingTimeInterval(
                TimeInterval(response.accessTokenExpiresIn)
            ),
            refreshToken: response.refreshToken,
            profile: existingProfile
        )
    }
}
