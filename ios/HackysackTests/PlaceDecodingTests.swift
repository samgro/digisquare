//
//  PlaceDecodingTests.swift
//  HackysackTests
//

import Foundation
import Testing
@testable import Hackysack

@Suite("Place decoding")
struct PlaceDecodingTests {
    @Test("Decodes the full result the API sends")
    func decodesFullResult() throws {
        let json = """
        {
          "id": "a2c1f0e4-6b7d-4e3a-9c1f-1d2e3f4a5b6c",
          "source": "user",
          "name": "Golden Gate Park",
          "address": "501 Stanyan St, San Francisco, CA 94117, US",
          "street": "501 Stanyan St",
          "locality": "San Francisco",
          "region": "US-CA",
          "postcode": "94117",
          "country": "US",
          "location": { "latitude": 37.7694, "longitude": -122.4862 },
          "types": ["park", "garden"],
          "primaryType": "park",
          "checkinCount": 61,
          "website": "https://sfrecpark.org",
          "phone": null
        }
        """
        let place = try RankingFixtures.makeDecoder().decode(Place.self, from: Data(json.utf8))

        #expect(place.source == .user)
        #expect(place.street == "501 Stanyan St")
        #expect(place.locality == "San Francisco")
        #expect(place.region == "US-CA")
        #expect(place.checkinCount == 61)
        #expect(place.website == "https://sfrecpark.org")
        #expect(place.phone == nil)
        #expect(PlaceFootprint(for: place).kind == .container)
    }

    @Test("Decodes a minimal result, defaulting the fields an older API build omits")
    func decodesMinimalResult() throws {
        let json = """
        {
          "id": "b2c1f0e4-6b7d-4e3a-9c1f-1d2e3f4a5b6c",
          "name": "Blue Bottle Coffee",
          "address": null,
          "location": null,
          "primaryType": null
        }
        """
        let place = try RankingFixtures.makeDecoder().decode(Place.self, from: Data(json.utf8))

        #expect(place.source == .overture)
        #expect(place.location == nil)
        #expect(place.types.isEmpty)
        #expect(place.checkinCount == 0)
        #expect(place.streetLine == nil)
    }

    @Test("An unknown source decodes rather than failing the whole list")
    func unknownSource() throws {
        let json = """
        { "id": "x", "source": "osm", "name": "Somewhere", "location": null }
        """
        let place = try RankingFixtures.makeDecoder().decode(Place.self, from: Data(json.utf8))
        #expect(place.source == .overture)
    }

    @Test("A checkin draft sends the place id, never the place's details")
    func draftEncodesPlaceIdOnly() throws {
        let place = Place(
            id: "c3c1f0e4-6b7d-4e3a-9c1f-1d2e3f4a5b6c",
            name: "Blue Bottle Coffee",
            address: "66 Mint St, San Francisco, CA 94103, US",
            location: PlaceLocation(latitude: 37.7823, longitude: -122.4076),
            types: ["coffee_shop"],
            primaryType: "coffee_shop"
        )
        let draft = CheckinDraft(place: place, message: "  hello  ")
        let encoded = try JSONEncoder().encode(draft)
        let object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])

        #expect(object["placeId"] as? String == place.id)
        #expect(object["message"] as? String == "hello")
        #expect(object["visibility"] as? String == "friends")
        #expect(object["source"] as? String == "manual")
        #expect(Set(object.keys) == ["placeId", "message", "visibility", "source"])
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
            for entry in fixture.histories.values.joined() {
                #expect(fixture.places.contains { $0.id == entry.placeId }, "\(name): history points at an unknown place")
            }
        }
    }
}
