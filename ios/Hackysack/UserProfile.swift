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
    let hasPassword: Bool
    let hasAppleSignIn: Bool
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, email, name, bio
        // Spelled avatarURL in Swift per the API Design Guidelines, which
        // uppercase acronyms; the wire format stays camelCase.
        case avatarURL = "avatarUrl"
        case hasPassword, hasAppleSignIn, createdAt
    }

    var initials: String { PersonName.initials(for: name) }

    var signInMethodDescription: String {
        switch (hasAppleSignIn, hasPassword) {
        case (true, true): return "Apple and email"
        case (true, false): return "Apple"
        case (false, true): return "Email & password"
        case (false, false): return "None"
        }
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
    /// Set when Sign in with Apple hit an email already held by a password
    /// account, so a separate account was created rather than linking them.
    let emailConflict: Bool?
}

struct RefreshResponse: Decodable, Sendable {
    let accessToken: String
    let accessTokenExpiresIn: Int
    let refreshToken: String
    let refreshTokenExpiresAt: Date
}
