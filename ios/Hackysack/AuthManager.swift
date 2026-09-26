//
//  AuthManager.swift
//  Hackysack
//

import Foundation
import Observation

enum AuthState: Equatable {
    /// Only ever shown when the Keychain was unreadable because the device is
    /// still locked. A normal launch resolves to signedIn or signedOut before
    /// the first body evaluation.
    case launching
    case signedOut
    /// Signed in, but missing a required profile field: no display name
    /// (Apple withholds fullName on every authorization after the first) or
    /// no hometown (every brand new account, which is how signup leads into
    /// profile setup).
    case needsProfileSetup(UserProfile)
    case signedIn(UserProfile)
}

@Observable
@MainActor
final class AuthManager {
    private(set) var state: AuthState = .launching
    var lastError: APIError?

    /// The signed-in user's profile, whether or not they have finished
    /// setting it up. Nil only before sign-in resolves.
    var currentProfile: UserProfile? {
        switch state {
        case .signedIn(let profile), .needsProfileSetup(let profile):
            return profile
        case .launching, .signedOut:
            return nil
        }
    }

    @ObservationIgnored private var sessionStore: AuthSessionStore!

    init() {
        // Read the Keychain SYNCHRONOUSLY here, so `state` is already correct
        // before SwiftUI first evaluates the root body. Doing this in a Task
        // would render .signedOut for one frame and flash the welcome screen
        // at every already-signed-in user.
        var stored: StoredCredentials?
        var isKeychainLocked = false
        do {
            stored = try KeychainStore.load()
            state = stored.map { Self.stateFor($0.profile) } ?? .signedOut
        } catch KeychainError.interactionNotAllowed {
            // Device still locked. Stay in .launching and retry rather than
            // deleting a session that is merely unreadable right now.
            isKeychainLocked = true
        } catch {
            state = .signedOut
        }

        // The store is created already holding the credentials, rather than
        // seeded afterwards in a Task. `state` says signed in from the first
        // frame, so the timeline fires its first request immediately; a
        // deferred seed could lose that race and the request would go out
        // with no token.
        //
        // The closure hops to the main actor because it drives `state`, which
        // SwiftUI reads.
        sessionStore = AuthSessionStore(credentials: stored) { [weak self] credentials in
            await self?.applyCredentials(credentials)
        }
        APIClient.shared.authSessionStore = sessionStore

        if isKeychainLocked {
            Task { await retryKeychainLoad() }
        } else {
            refreshIfProfileLooksIncomplete()
        }
    }

    /// A profile cached before hometown existed decodes with no hometown, so
    /// an existing user would be held on profile setup even though the server
    /// has theirs. Ask the server before believing the cache; if it really is
    /// incomplete, nothing changes and setup stays up.
    private func refreshIfProfileLooksIncomplete() {
        guard case .needsProfileSetup = state else { return }
        Task { await refreshProfile() }
    }

    private static func stateFor(_ profile: UserProfile) -> AuthState {
        profile.isMissingRequiredFields ? .needsProfileSetup(profile) : .signedIn(profile)
    }

    private func retryKeychainLoad() async {
        for _ in 0..<10 {
            try? await Task.sleep(for: .seconds(1))
            do {
                let stored = try KeychainStore.load()
                await sessionStore.seed(stored)
                applyCredentials(stored)
                refreshIfProfileLooksIncomplete()
                return
            } catch KeychainError.interactionNotAllowed {
                continue
            } catch {
                state = .signedOut
                return
            }
        }
        state = .signedOut
    }

    private func applyCredentials(_ credentials: StoredCredentials?) {
        guard let credentials else {
            state = .signedOut
            return
        }
        state = Self.stateFor(credentials.profile)
    }

    // MARK: - Sign in

    /// - Parameter nonce: the RAW nonce. iOS sends Apple the SHA-256 of it;
    ///   the server hashes this and compares against what Apple echoed back.
    func signInWithApple(
        identityToken: String,
        nonce: String,
        fullName: PersonNameComponents?,
        email: String?
    ) async throws -> Bool {
        struct AppleRequest: Encodable {
            struct FullName: Encodable {
                let givenName: String?
                let familyName: String?
            }
            let identityToken: String
            let nonce: String
            let fullName: FullName?
            let email: String?
        }

        // fullName and email are non-nil ONLY on the very first authorization
        // for this Apple ID. There is no second chance to capture them, which
        // is why they are sent on every attempt and the server backfills only
        // where its own columns are still null.
        let name = fullName.map {
            AppleRequest.FullName(givenName: $0.givenName, familyName: $0.familyName)
        }

        let response: AuthResponse = try await APIClient.shared.request(
            method: "POST",
            path: "auth/apple",
            body: AppleRequest(
                identityToken: identityToken,
                nonce: nonce,
                fullName: name,
                email: email
            ),
            authenticated: false
        )
        await adopt(response)
        return response.emailConflict == true
    }

    #if DEBUG
    // MARK: - Test users

    /// Every test user, oldest first. The API only serves these when
    /// ENABLE_TEST_USERS is set.
    func fetchTestUsers() async throws -> [UserSummary] {
        struct TestUsersResponse: Decodable {
            let results: [UserSummary]
        }

        let response: TestUsersResponse = try await APIClient.shared.request(
            path: "auth/test-users",
            authenticated: false
        )
        return response.results
    }

    func signInAsTestUser(id: String) async throws {
        let response: AuthResponse = try await APIClient.shared.request(
            method: "POST",
            path: "auth/test-users/\(id)/session",
            authenticated: false
        )
        await adopt(response)
    }

    /// Creates a test user with no name, which lands in profile setup just as
    /// a brand-new Apple account does.
    func createTestUser() async throws {
        let response: AuthResponse = try await APIClient.shared.request(
            method: "POST",
            path: "auth/test-users",
            authenticated: false
        )
        await adopt(response)
    }
    #endif

    private func adopt(_ response: AuthResponse) async {
        await sessionStore.adopt(
            StoredCredentials(
                accessToken: response.accessToken,
                accessTokenExpiresAt: Date().addingTimeInterval(
                    TimeInterval(response.accessTokenExpiresIn)
                ),
                refreshToken: response.refreshToken,
                profile: response.user
            )
        )
    }

    // MARK: - Session

    func signOut() async {
        struct LogoutRequest: Encodable {
            let refreshToken: String
        }

        if let refreshToken = await sessionStore.currentCredentials()?.refreshToken {
            // Best effort. Failing to reach the server must not leave the user
            // stuck signed in on this device.
            try? await APIClient.shared.send(
                method: "POST",
                path: "auth/logout",
                body: LogoutRequest(refreshToken: refreshToken),
                authenticated: false
            )
        }
        await sessionStore.signOut(reason: .userInitiated)
    }

    /// Re-fetches the profile. A failure here never discards what we have —
    /// showing a correct cached screen beats showing an error screen.
    func refreshProfile() async {
        do {
            let profile: UserProfile = try await APIClient.shared.request(path: "users/me")
            await sessionStore.updateProfile(profile)
        } catch {
            lastError = error as? APIError
        }
    }

    /// Returns the profile as the server saved it, which can differ from what
    /// was sent: an api without a field silently drops it.
    @discardableResult
    func updateProfile(
        name: ProfileFieldUpdate,
        bio: ProfileFieldUpdate,
        avatarKey: ProfileFieldUpdate,
        hometown: ProfileFieldUpdate
    ) async throws -> UserProfile {
        struct UpdateRequest: Encodable {
            let name: ProfileFieldUpdate
            let bio: ProfileFieldUpdate
            let avatarKey: ProfileFieldUpdate
            let hometown: ProfileFieldUpdate

            enum CodingKeys: String, CodingKey {
                case name, bio, avatarKey, hometown
            }

            // Written by hand because the synthesized conformance uses
            // encodeIfPresent for optionals, which OMITS nil. The server
            // treats an absent key as "leave this alone" and an explicit null
            // as "clear it", so a synthesized encoder could never clear a
            // field.
            func encode(to encoder: any Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try name.encode(into: &container, forKey: .name)
                try bio.encode(into: &container, forKey: .bio)
                try avatarKey.encode(into: &container, forKey: .avatarKey)
                try hometown.encode(into: &container, forKey: .hometown)
            }
        }

        let profile: UserProfile = try await APIClient.shared.request(
            method: "PATCH",
            path: "users/me",
            body: UpdateRequest(name: name, bio: bio, avatarKey: avatarKey, hometown: hometown)
        )
        await sessionStore.updateProfile(profile)
        return profile
    }

    /// Uploads avatar bytes straight to R2 and returns the key to attach.
    func uploadAvatar(_ jpegData: Data) async throws -> String {
        try await APIClient.shared.uploadJPEG(jpegData, uploadPath: "users/me/avatar-upload")
    }
}
