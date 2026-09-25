//
//  ProfileTests.swift
//  HackysackTests
//

import Foundation
import Testing
@testable import Hackysack

@Suite("Profile")
struct ProfileTests {
    private static func decodeProfile(name: String?, hometown: String?) throws -> UserProfile {
        let payload: [String: Any?] = [
            "id": "550e8400-e29b-41d4-a716-446655440000",
            "email": "someone@example.com",
            "name": name,
            "bio": nil,
            "avatarUrl": nil,
            "hometown": hometown,
            "hasAppleSignIn": false,
            "createdAt": "2026-09-18T00:00:00Z",
        ]
        let json = try JSONSerialization.data(
            withJSONObject: payload.mapValues { $0 ?? NSNull() }
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(UserProfile.self, from: json)
    }

    @Test("A profile with a name and hometown is complete")
    func completeProfile() throws {
        let profile = try Self.decodeProfile(name: "Sam", hometown: "Truckee, CA")
        #expect(profile.hometown == "Truckee, CA")
        #expect(!profile.isMissingRequiredFields)
    }

    // Every brand new account arrives like this, which is what sends signup
    // into profile setup.
    @Test("A new account with no hometown needs setup")
    func missingHometown() throws {
        let profile = try Self.decodeProfile(name: "Sam", hometown: nil)
        #expect(profile.isMissingRequiredFields)
    }

    @Test("A blank hometown counts as missing")
    func blankHometown() throws {
        let profile = try Self.decodeProfile(name: "Sam", hometown: "   ")
        #expect(profile.isMissingRequiredFields)
    }

    @Test("A missing name still needs setup")
    func missingName() throws {
        let profile = try Self.decodeProfile(name: nil, hometown: "Truckee, CA")
        #expect(profile.isMissingRequiredFields)
    }
}
