//
//  APIClient.swift
//  Hackysack
//

import Foundation

/// Placeholder body for requests that send nothing, so the bodyless overload
/// can forward to the generic one without an ambiguous `nil`.
struct EmptyRequestBody: Encodable {}

/// Empty response for endpoints that return 204.
struct EmptyResponse: Decodable {}

/// The `{ results: [...] }` envelope every list endpoint answers with.
struct ResultsResponse<Item: Decodable>: Decodable {
    let results: [Item]
}

/// The `limit` and `before` query items every newest-first list takes. The
/// cursor is the `createdAt` of the last row already loaded, sent with
/// fractional seconds: the server keeps milliseconds and the comparison is
/// exclusive, so a cursor rounded to the second would skip rows.
enum ListPagination {
    private static let cursorFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func queryItems(limit: Int, before: Date?) -> [URLQueryItem] {
        var items = [URLQueryItem(name: "limit", value: String(limit))]
        if let before {
            items.append(URLQueryItem(name: "before", value: cursorFormatter.string(from: before)))
        }
        return items
    }
}

final class APIClient {
    static let shared = APIClient()

    /// Set once at launch by AuthManager. Nil until then, which is why
    /// unauthenticated calls must pass `authenticated: false` rather than
    /// relying on it being absent.
    var authSessionStore: AuthSessionStore?

    private let urlSession: URLSession = .shared
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        // The API validates dates such as a checkin's backdated `createdAt`
        // as ISO 8601 timestamps; the default would send seconds since 2001.
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
    private let decoder: JSONDecoder = APIClient.makeDecoder()

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            // Hono serializes Date with toISOString(), which ALWAYS emits
            // fractional seconds ("2026-09-20T12:34:56.789Z"). The built-in
            // .iso8601 strategy rejects those outright, so this has to be
            // custom. The second formatter is a fallback in case a value ever
            // arrives without them.
            if let date = ISO8601DateFormatter.hackysackWithFractionalSeconds.date(from: text) {
                return date
            }
            if let date = ISO8601DateFormatter.hackysackPlain.date(from: text) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unrecognized date format: \(text)"
            )
        }
        return decoder
    }

    // MARK: - Requests

    func request<Response: Decodable>(
        method: String = "GET",
        path: String,
        queryItems: [URLQueryItem] = [],
        authenticated: Bool = true,
        bypassingBuildGate: Bool = false
    ) async throws -> Response {
        try await request(
            method: method,
            path: path,
            queryItems: queryItems,
            body: Optional<EmptyRequestBody>.none,
            authenticated: authenticated,
            bypassingBuildGate: bypassingBuildGate
        )
    }

    /// `bypassingBuildGate` is for the gate's own re-check of the server,
    /// the one request that must go out while everything else is blocked.
    func request<Body: Encodable, Response: Decodable>(
        method: String = "GET",
        path: String,
        queryItems: [URLQueryItem] = [],
        body: Body?,
        authenticated: Bool = true,
        bypassingBuildGate: Bool = false
    ) async throws -> Response {
        let (data, response) = try await perform(
            try buildRequest(method: method, path: path, queryItems: queryItems, body: body),
            authenticated: authenticated,
            allowRefreshRetry: true,
            bypassingBuildGate: bypassingBuildGate
        )

        try throwIfFailure(data: data, response: response)

        if Response.self == EmptyResponse.self {
            return EmptyResponse() as! Response
        }

        do {
            return try decoder.decode(Response.self, from: data)
        } catch {
            DevLog.network("✗ Failed to decode \(Response.self) from \(path): \(error)")
            throw APIError.decoding(error)
        }
    }

    /// For endpoints that return 204 and no body.
    func send<Body: Encodable>(
        method: String,
        path: String,
        body: Body?,
        authenticated: Bool = true
    ) async throws {
        let (data, response) = try await perform(
            try buildRequest(method: method, path: path, queryItems: [], body: body),
            authenticated: authenticated,
            allowRefreshRetry: true
        )
        try throwIfFailure(data: data, response: response)
    }

    // MARK: - Uploads

    /// Asks our API at `uploadPath` for a presigned URL, PUTs the JPEG
    /// straight to storage, and returns the key to attach to whatever the
    /// image belongs to.
    func uploadJPEG(_ jpegData: Data, uploadPath: String) async throws -> String {
        struct UploadRequest: Encodable {
            let contentType: String
            let contentLength: Int
        }

        let upload: ImageUpload = try await request(
            method: "POST",
            path: uploadPath,
            body: UploadRequest(contentType: "image/jpeg", contentLength: jpegData.count)
        )

        var putRequest = URLRequest(url: upload.uploadUrl)
        putRequest.httpMethod = "PUT"
        // Must match what the server signed, byte for byte. URLSession sets
        // Content-Length from the body itself. Do NOT set Authorization: it
        // conflicts with the query-string credentials and R2 answers 403.
        putRequest.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")

        // Deliberately not perform(): this request goes to R2, not to our
        // API, and must carry no bearer token.
        let (_, response) = try await urlSession.upload(for: putRequest, from: jpegData)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw APIError.invalidResponse
        }

        return upload.key
    }

    // MARK: - Plumbing

    private func buildRequest<Body: Encodable>(
        method: String,
        path: String,
        queryItems: [URLQueryItem],
        body: Body?
    ) throws -> URLRequest {
        var components = URLComponents(
            url: APIEnvironment.baseURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        )!
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }

        var urlRequest = URLRequest(url: components.url!)
        urlRequest.httpMethod = method
        if let body {
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            urlRequest.httpBody = try encoder.encode(body)
        }
        return urlRequest
    }

    private func perform(
        _ originalRequest: URLRequest,
        authenticated: Bool,
        allowRefreshRetry: Bool,
        bypassingBuildGate: Bool = false
    ) async throws -> (Data, HTTPURLResponse) {
        var urlRequest = originalRequest
        var attachedAccessToken: String?

        // Simulator builds on localhost first find which local port serves
        // this build's branch; production's URL is fixed.
        await DevServerLocator.shared.ensureLocated()

        // A dev server from another checkout gets nothing at all, so no
        // session or write can land in its database by accident.
        if !bypassingBuildGate, BuildGate.shared.isBlocking,
           let server = BuildGate.shared.server, let app = BuildGate.shared.app {
            DevLog.network("✗ \(originalRequest.url?.path ?? "") skipped: server is \(server.wireValue), this build is \(app.wireValue)")
            throw APIError.wrongServer(server: server.wireValue, app: app.wireValue)
        }
        // Only dev servers check the build; production is never sent it.
        if APIEnvironment.server == .localhost, let app = BuildIdentity.app {
            urlRequest.setValue(app.wireValue, forHTTPHeaderField: "X-Hackysack-Client-Build")
        }

        if authenticated {
            guard let store = authSessionStore,
                  let accessToken = await store.currentAccessToken() else {
                DevLog.network("✗ \(originalRequest.url?.path ?? "") skipped: no access token")
                throw APIError.unauthorized
            }
            attachedAccessToken = accessToken
            urlRequest.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }

        let requestDescription = "\(urlRequest.httpMethod ?? "GET") \(urlRequest.url?.absoluteString ?? "<no url>")"
        DevLog.network("→ \(requestDescription)")
        let startTime = ContinuousClock.now

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: urlRequest)
        } catch {
            DevLog.network("✗ \(requestDescription) failed after \(ContinuousClock.now - startTime): \(error)")
            // A dropped connection is not a credential problem. Surfacing it
            // as .transport keeps it away from the sign-out path below, so a
            // tunnel or a flaky network never logs the user out.
            throw APIError.transport(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            DevLog.network("✗ \(requestDescription) returned a non-HTTP response")
            throw APIError.invalidResponse
        }

        DevLog.network("← \(httpResponse.statusCode) \(requestDescription) (\(data.count) bytes, \(ContinuousClock.now - startTime))")
        if !(200..<300).contains(httpResponse.statusCode) {
            DevLog.network("  body: \(String(decoding: data.prefix(1000), as: UTF8.self))")
        }

        // Every response names the server's build; a 409 with the mismatch
        // body is the server refusing this build outright.
        BuildGate.shared.record(serverWireValue: httpResponse.value(forHTTPHeaderField: "X-Hackysack-Build"))
        if httpResponse.statusCode == 409,
           let mismatch = try? decoder.decode(BuildMismatchBody.self, from: data),
           mismatch.code == BuildMismatchBody.code {
            BuildGate.shared.record(server: mismatch.server.identity)
            throw APIError.wrongServer(server: mismatch.server.identity.wireValue, app: mismatch.client.identity.wireValue)
        }

        if httpResponse.statusCode == 401,
           authenticated,
           allowRefreshRetry,
           let store = authSessionStore,
           let attachedAccessToken {
            DevLog.network("  401 — refreshing credentials and retrying once")
            do {
                // Passing the token we actually used lets the store tell
                // "nobody has refreshed yet" apart from "someone already
                // refreshed while this request was in flight".
                _ = try await store.refreshedCredentials(replacing: attachedAccessToken)
            } catch {
                // The refresh itself was rejected — the refresh token is spent
                // or revoked. This is the ONLY path that signs the user out.
                await store.signOut(reason: .refreshRejected)
                throw APIError.unauthorized
            }
            // Exactly one retry, with whatever token the store now holds.
            return try await perform(
                originalRequest,
                authenticated: true,
                allowRefreshRetry: false,
                bypassingBuildGate: bypassingBuildGate
            )
        }

        return (data, httpResponse)
    }

    private func throwIfFailure(data: Data, response: HTTPURLResponse) throws {
        guard !(200..<300).contains(response.statusCode) else { return }

        let body = try? decoder.decode(APIErrorBody.self, from: data)

        if response.statusCode == 429 {
            let headerValue = response.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init)
            throw APIError.rateLimited(
                retryAfterSeconds: body?.retryAfterSeconds ?? headerValue ?? 60
            )
        }

        if response.statusCode == 401 {
            throw APIError.unauthorized
        }

        guard let body else {
            throw APIError.invalidResponse
        }

        throw APIError.server(
            statusCode: response.statusCode,
            message: body.error,
            fieldErrors: body.details?.fieldErrors ?? [:]
        )
    }
}

extension ISO8601DateFormatter {
    static let hackysackWithFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static let hackysackPlain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
