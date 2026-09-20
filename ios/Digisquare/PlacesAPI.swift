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

enum PlacesAPIError: Error {
    case badResponse
}

struct PlacesAPI {
    func searchPlaces(latitude: Double, longitude: Double, query: String? = nil, radius: Double? = nil) async throws -> [Place] {
        var components = URLComponents(url: APIEnvironment.baseURL.appendingPathComponent("places"), resolvingAgainstBaseURL: false)!
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
        components.queryItems = queryItems

        let (data, response) = try await URLSession.shared.data(from: components.url!)
        guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) else {
            throw PlacesAPIError.badResponse
        }
        return try JSONDecoder().decode(PlacesResponse.self, from: data).results
    }
}
