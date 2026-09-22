//
//  APIError.swift
//  Hackysack
//

import Foundation

/// The API's error body. `details` mirrors zod's `error.flatten()`, which is
/// why `fieldErrors` is keyed by the server's own schema field names.
struct APIErrorBody: Decodable {
    let error: String
    let details: Details?
    let retryAfterSeconds: Int?

    struct Details: Decodable {
        let formErrors: [String]
        let fieldErrors: [String: [String]]
    }
}

enum APIError: LocalizedError {
    case unauthorized
    case rateLimited(retryAfterSeconds: Int)
    case server(statusCode: Int, message: String, fieldErrors: [String: [String]])
    case invalidResponse
    case decoding(any Error)
    case transport(any Error)

    // Conforming to LocalizedError is what makes error.localizedDescription
    // useful. The previous PlacesAPIError did not, so every failure in
    // CheckInView surfaced as Foundation's generic "The operation couldn't be
    // completed."
    var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "Your session expired. Please sign in again."
        case .rateLimited(let retryAfterSeconds):
            let minutes = max(1, Int((Double(retryAfterSeconds) / 60).rounded(.up)))
            return "Too many attempts. Try again in \(minutes) minute\(minutes == 1 ? "" : "s")."
        case .server(_, let message, _):
            // The API writes these to be read by a person, so pass them
            // through rather than inventing our own wording.
            return message
        case .invalidResponse:
            return "The server sent an unexpected response."
        case .decoding:
            return "The server sent something we couldn't read."
        case .transport:
            // Carried over from PlacesAPIError, which this replaces. Friendlier
            // than NSError's default and it names the app, so the user knows
            // which connection is at fault.
            return "We couldn't reach \(AppInfo.name). Check your connection and try again."
        }
    }

    /// The validation message for one field, so a 400 can light up the field
    /// that actually failed instead of showing a generic banner.
    func message(forField fieldName: String) -> String? {
        guard case .server(_, _, let fieldErrors) = self else { return nil }
        return fieldErrors[fieldName]?.first
    }

    var isUnauthorized: Bool {
        if case .unauthorized = self { return true }
        return false
    }
}
