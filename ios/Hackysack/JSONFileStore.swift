//
//  JSONFileStore.swift
//  Hackysack
//

import Foundation
import os

/// Where the app keeps its own files, outside of anything the user can see.
enum AppSupportDirectory {
    static var url: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appending(path: "Hackysack", directoryHint: .isDirectory)
    }
}

/// Reads and writes one `Codable` value as a JSON file. Writes are atomic, so a
/// crash mid-save leaves the previous file intact rather than a truncated one.
struct JSONFileStore<Value: Codable> {
    let fileURL: URL

    private static var logger: Logger { Logger(subsystem: "samgro.Hackysack", category: "JSONFileStore") }

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    init(fileName: String) {
        self.init(fileURL: AppSupportDirectory.url.appending(path: fileName, directoryHint: .notDirectory))
    }

    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    /// The stored value, or `nil` when the file is missing or unreadable. A file
    /// that fails to decode is treated as missing so a schema change never
    /// wedges the app; the next save replaces it.
    func load() -> Value? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        do {
            return try decoder.decode(Value.self, from: data)
        } catch {
            Self.logger.error("Discarding unreadable \(fileURL.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    func save(_ value: Value) {
        do {
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try encoder.encode(value)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Self.logger.error("Failed to save \(fileURL.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}
