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
    /// Signed in, but with no display name. Reached when Apple withheld
    /// fullName, which it does on every authorization after the first.
    case needsProfileSetup(UserProfile)
    case signedIn(UserProfile)
}

@Observable
@MainActor
final class AuthManager {
    private(set) var state: AuthState = .launching
    var lastError: APIError?

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
        }
    }

    private static func stateFor(_ profile: UserProfile) -> AuthState {
        let trimmedName = profile.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmedName.isEmpty ? .needsProfileSetup(profile) : .signedIn(profile)
    }

    private func retryKeychainLoad() async {
        for _ in 0..<10 {
            try? await Task.sleep(for: .seconds(1))
            do {
                let stored = try KeychainStore.load()
                await sessionStore.seed(stored)
                applyCredentials(stored)
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

    func register(email: String, password: String, name: String) async throws {
        struct RegisterRequest: Encodable {
            let email: String
            let password: String
            let name: String?
        }

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let response: AuthResponse = try await APIClient.shared.request(
            method: "POST",
            path: "auth/register",
            body: RegisterRequest(
                email: email.trimmingCharacters(in: .whitespacesAndNewlines),
                // Deliberately not trimmed: leading and trailing spaces are
                // part of the password.
                password: password,
                name: trimmedName.isEmpty ? nil : trimmedName
            ),
            authenticated: false
        )
        await adopt(response)
    }

    func signIn(email: String, password: String) async throws {
        struct LoginRequest: Encodable {
            let email: String
            let password: String
        }

        let response: AuthResponse = try await APIClient.shared.request(
            method: "POST",
            path: "auth/login",
            body: LoginRequest(
                email: email.trimmingCharacters(in: .whitespacesAndNewlines),
                password: password
            ),
            authenticated: false
        )
        await adopt(response)
    }

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

    func updateProfile(
        name: ProfileFieldUpdate,
        bio: ProfileFieldUpdate,
        avatarKey: ProfileFieldUpdate
    ) async throws {
        struct UpdateRequest: Encodable {
            let name: ProfileFieldUpdate
            let bio: ProfileFieldUpdate
            let avatarKey: ProfileFieldUpdate

            enum CodingKeys: String, CodingKey {
                case name, bio, avatarKey
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
            }
        }

        let profile: UserProfile = try await APIClient.shared.request(
            method: "PATCH",
            path: "users/me",
            body: UpdateRequest(name: name, bio: bio, avatarKey: avatarKey)
        )
        await sessionStore.updateProfile(profile)
    }

    /// Uploads avatar bytes straight to R2 and returns the key to attach.
    func uploadAvatar(_ jpegData: Data) async throws -> String {
        struct UploadRequest: Encodable {
            let contentType: String
            let contentLength: Int
        }
        struct UploadResponse: Decodable {
            let uploadUrl: URL
            let key: String
            let expiresInSeconds: Int
            let maxBytes: Int
        }

        let upload: UploadResponse = try await APIClient.shared.request(
            method: "POST",
            path: "users/me/avatar-upload",
            body: UploadRequest(contentType: "image/jpeg", contentLength: jpegData.count)
        )

        var putRequest = URLRequest(url: upload.uploadUrl)
        putRequest.httpMethod = "PUT"
        // Must match what the server signed, byte for byte. URLSession sets
        // Content-Length from the body itself. Do NOT set Authorization: it
        // conflicts with the query-string credentials and R2 answers 403.
        putRequest.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")

        // Deliberately a bare URLSession rather than APIClient — this request
        // goes to R2, not to our API, and must carry no bearer token.
        let (_, response) = try await URLSession.shared.upload(for: putRequest, from: jpegData)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw APIError.invalidResponse
        }

        return upload.key
    }
}
