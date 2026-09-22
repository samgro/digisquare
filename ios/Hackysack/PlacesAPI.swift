//
//  PlacesAPI.swift
//  Hackysack
//

import Foundation

struct Place: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let address: String?
    let location: PlaceLocation?
    let types: [String]
    let primaryType: String?
    let rating: Double?
    let userRatingCount: Int?
}

struct PlaceLocation: Decodable, Hashable {
    let latitude: Double
    let longitude: Double
}

private struct PlacesResponse: Decodable {
    let results: [Place]
}

struct PlacesAPI {
    private let client: APIClient

    init(client: APIClient = .shared) {
        self.client = client
    }

    func searchPlaces(
        latitude: Double,
        longitude: Double,
        query: String? = nil,
        radius: Double? = nil
    ) async throws -> [Place] {
        // The abbreviated names here are the API's query parameters, which is
        // the one place CLAUDE.md permits them. The Swift labels above are
        // spelled out.
        var queryItems = [
            URLQueryItem(name: "lat", value: String(latitude)),
            URLQueryItem(name: "lng", value: String(longitude)),
        ]
        if let query, !query.isEmpty {
            queryItems.append(URLQueryItem(name: "q", value: query))
        }
        if let radius, radius > 0 {
            queryItems.append(URLQueryItem(name: "radius", value: String(Int(radius.rounded()))))
        }

        let response: PlacesResponse = try await client.request(
            path: "places",
            queryItems: queryItems,
            // /places is open, and the checkin flow must keep working while
            // a token refresh is in flight.
            authenticated: false
        )
        return response.results
    }
}
