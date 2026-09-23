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

    @Test("Decodes profile stats with top places")
    func decodesStats() throws {
        let json = """
        {
          "checkinCount": 7,
          "placeCount": 3,
          "topPlaces": [
            { "googlePlaceId": "ChIJcafe", "placeName": "Coffee Bar",
              "placePrimaryType": "cafe", "checkinCount": 4 },
            { "googlePlaceId": "ChIJpark", "placeName": "Golden Gate Park",
              "placePrimaryType": null, "checkinCount": 2 }
          ]
        }
        """
        let stats = try JSONDecoder().decode(ProfileStats.self, from: Data(json.utf8))

        #expect(stats.checkinCount == 7)
        #expect(stats.placeCount == 3)
        #expect(stats.topPlaces.map(\.id) == ["ChIJcafe", "ChIJpark"])
        #expect(stats.topPlaces[1].placePrimaryType == nil)
    }

    @Test("Decodes stats for someone with no checkins")
    func decodesEmptyStats() throws {
        let json = #"{ "checkinCount": 0, "placeCount": 0, "topPlaces": [] }"#
        let stats = try JSONDecoder().decode(ProfileStats.self, from: Data(json.utf8))

        #expect(stats.checkinCount == 0)
        #expect(stats.topPlaces.isEmpty)
    }
}
