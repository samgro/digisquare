//
//  UserProfile.swift
//  Hackysack
//

import Foundation

// These models cross actors — they are read and written on the AuthSessionStore
// actor as well as the main one — so they opt out of the target's default
// @MainActor isolation. Without `nonisolated` their synthesized Codable
// conformances are main actor-isolated and unusable from KeychainStore.
nonisolated struct UserProfile: Codable, Identifiable, Equatable, Sendable {
    let id: String
    /// Null for an Apple user who hid their address, and for an account
    /// created by the server's email-collision path.
    let email: String?
    let name: String?
    let bio: String?
    let avatarURL: URL?
    /// Display text such as "San Francisco, CA". Required, but null on the
    /// wire until a new account finishes profile setup — the gate in
    /// AuthManager.stateFor keeps the user on that screen until it is set.
    let hometown: String?
    let hasAppleSignIn: Bool
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, email, name, bio
        // Spelled avatarURL in Swift per the API Design Guidelines, which
        // uppercase acronyms; the wire format stays camelCase.
        case avatarURL = "avatarUrl"
        case hometown, hasAppleSignIn, createdAt
    }

    var initials: String { PersonName.initials(for: name) }

    /// True until the user has both a display name and a hometown. Drives the
    /// profile setup gate.
    var isMissingRequiredFields: Bool {
        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let trimmedHometown = hometown?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmedName.isEmpty || trimmedHometown.isEmpty
    }

    /// Apple is the only real sign-in method, so an account without it is a
    /// test user from the debug build's picker.
    var signInMethodDescription: String {
        hasAppleSignIn ? "Apple" : "Test user"
    }
}

/// Everything needed to resume a session, stored as a single Keychain item so
/// the root gate can decide what to show without an async read.
nonisolated struct StoredCredentials: Codable, Equatable, Sendable {
    var accessToken: String
    var accessTokenExpiresAt: Date
    var refreshToken: String
    var profile: UserProfile
}

struct AuthResponse: Decodable, Sendable {
    let user: UserProfile
    let accessToken: String
    let accessTokenExpiresIn: Int
    let refreshToken: String
    let refreshTokenExpiresAt: Date
    /// Set when Sign in with Apple hit an email already held by another
    /// account, so a separate account was created rather than linking them.
    let emailConflict: Bool?
}

struct RefreshResponse: Decodable, Sendable {
    let accessToken: String
    let accessTokenExpiresIn: Int
    let refreshToken: String
    let refreshTokenExpiresAt: Date
}
