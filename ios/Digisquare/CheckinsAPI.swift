//
//  CheckinsAPI.swift
//  Digisquare
//

import Foundation

/// A checkin as returned by the API (`GET /checkins`, `POST /checkins`).
struct Checkin: Decodable, Identifiable, Equatable {
    let id: String
    let userId: String
    let googlePlaceId: String
    let placeName: String
    let placeAddress: String?
    let placePrimaryType: String?
    let placeTypes: [String]?
    let location: PlaceLocation?
    let message: String?
    let createdAt: Date
    let updatedAt: Date
}

/// The request body for `POST /checkins`. Coordinates are flat here but nested
/// under `location` in the response, so this is deliberately not derived from `Checkin`.
struct CheckinDraft: Encodable, Equatable {
    let userId: String
    let googlePlaceId: String
    let placeName: String
    let placeAddress: String?
    let placePrimaryType: String?
    let placeTypes: [String]?
    let latitude: Double?
    let longitude: Double?
    let message: String?

    init(place: Place, message: String?, userId: String = CurrentUser.userId) {
        self.userId = userId
        googlePlaceId = place.id
        placeName = place.name
        placeAddress = Self.trimmedOrNil(place.address)
        placePrimaryType = Self.trimmedOrNil(place.primaryType)
        placeTypes = place.types.isEmpty ? nil : place.types
        latitude = place.location?.latitude
        longitude = place.location?.longitude
        self.message = Self.trimmedOrNil(message)
    }

    /// The API rejects empty strings for optional text fields, so they are omitted instead.
    private static func trimmedOrNil(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

private struct CheckinsResponse: Decodable {
    let results: [Checkin]
}

enum CheckinsAPIError: LocalizedError {
    case badResponse(statusCode: Int)

    var errorDescription: String? {
        switch self {
        case .badResponse(let statusCode):
            return "The server responded with status \(statusCode)."
        }
    }
}

struct CheckinsAPI {
    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        // The API serializes timestamps as JavaScript dates ("2026-09-20T12:34:56.789Z"),
        // which the stock `.iso8601` strategy rejects because of the fractional seconds.
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let rawValue = try container.decode(String.self)
            if let date = try? Date(rawValue, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) {
                return date
            }
            if let date = try? Date(rawValue, strategy: Date.ISO8601FormatStyle()) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unrecognized date: \(rawValue)")
        }
        return decoder
    }()

    func createCheckin(_ draft: CheckinDraft) async throws -> Checkin {
        var request = URLRequest(url: APIEnvironment.baseURL.appendingPathComponent("checkins"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(draft)

        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.validate(response)
        return try Self.decoder.decode(Checkin.self, from: data)
    }

    func listCheckins(userId: String? = nil, limit: Int = 50, offset: Int = 0) async throws -> [Checkin] {
        var components = URLComponents(url: APIEnvironment.baseURL.appendingPathComponent("checkins"), resolvingAgainstBaseURL: false)!
        var queryItems = [
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "offset", value: String(offset)),
        ]
        if let userId {
            queryItems.append(URLQueryItem(name: "userId", value: userId))
        }
        components.queryItems = queryItems

        let (data, response) = try await URLSession.shared.data(from: components.url!)
        try Self.validate(response)
        return try Self.decoder.decode(CheckinsResponse.self, from: data).results
    }

    private static func validate(_ response: URLResponse) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CheckinsAPIError.badResponse(statusCode: 0)
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw CheckinsAPIError.badResponse(statusCode: httpResponse.statusCode)
        }
    }
}
