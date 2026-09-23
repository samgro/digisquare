//
//  PlaceDecodingTests.swift
//  HackysackTests
//

import Foundation
import Testing
@testable import Hackysack

@Suite("Place decoding")
struct PlaceDecodingTests {
    @Test("Decodes the viewport the API now sends")
    func decodesViewport() throws {
        let json = """
        {
          "id": "ChIJpark",
          "name": "Golden Gate Park",
          "address": "San Francisco, CA, USA",
          "location": { "latitude": 37.7694, "longitude": -122.4862 },
          "viewport": {
            "low": { "latitude": 37.7644, "longitude": -122.5107 },
            "high": { "latitude": 37.7745, "longitude": -122.4544 }
          },
          "types": ["park", "tourist_attraction"],
          "primaryType": "park",
          "rating": 4.8,
          "userRatingCount": 61307
        }
        """
        let place = try RankingFixtures.makeDecoder().decode(Place.self, from: Data(json.utf8))

        #expect(place.viewport?.low.latitude == 37.7644)
        #expect(place.viewport?.high.longitude == -122.4544)
        #expect(PlaceFootprint(for: place).rectangle != nil)
    }

    @Test("Still decodes responses from an API build without viewports")
    func decodesWithoutViewport() throws {
        let json = """
        {
          "id": "ChIJcafe",
          "name": "Blue Bottle Coffee",
          "address": null,
          "location": null,
          "types": [],
          "primaryType": null,
          "rating": null,
          "userRatingCount": null
        }
        """
        let place = try RankingFixtures.makeDecoder().decode(Place.self, from: Data(json.utf8))

        #expect(place.viewport == nil)
        #expect(place.location == nil)
        #expect(place.types.isEmpty)
    }

    @Test("Every recorded scenario decodes with the app's decoder")
    func fixturesDecode() throws {
        for name in try RankingFixtures.names() {
            let fixture = try RankingFixtures.load(name)
            #expect(!fixture.places.isEmpty, "\(name) has no places")
            #expect(!fixture.cases.isEmpty, "\(name) has no cases")
            for (key, identifier) in fixture.placeKeys {
                #expect(fixture.places.contains { $0.id == identifier }, "\(name): key \(key) points at an unknown place")
            }
        }
    }
}
