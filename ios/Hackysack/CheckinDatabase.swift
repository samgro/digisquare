//
//  CheckinDatabase.swift
//  Hackysack
//

import Foundation
import SwiftData

/// Where each signed-in user's local copy of their checkins lives.
///
/// Every account gets its own store file, so one user's history can never be
/// served to another on a shared device, and signing out is just deleting a
/// directory. Simulator builds that switch API servers get one per server
/// too: a Neon branch shares its user ids with production, so the id alone
/// would mix the two servers' checkins. The data is only a cache of the server, which is why it is
/// excluded from backups and thrown away rather than migrated when it can't
/// be opened.
enum CheckinDatabase {
    private static let schema = Schema([CheckinRecord.self, CheckinSyncState.self])

    private static var rootDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "CheckinDatabases", directoryHint: .isDirectory)
    }

    private static func directoryName(forUserId userId: String) -> String {
        "\(APIEnvironment.server.rawValue)-\(userId)"
    }

    private static func directory(forUserId userId: String) -> URL {
        rootDirectory.appending(path: directoryName(forUserId: userId), directoryHint: .isDirectory)
    }

    /// Opens (or creates) the store for this user, falling back to starting
    /// over and then to memory only — search should degrade to "syncs every
    /// launch", never to a crash.
    static func makeContainer(userId: String) -> ModelContainer {
        removeDatabases(except: userId)

        if let container = try? openContainer(userId: userId) {
            return container
        }
        DevLog.network("Checkin database for \(userId) couldn't be opened; starting over")
        try? FileManager.default.removeItem(at: directory(forUserId: userId))
        if let container = try? openContainer(userId: userId) {
            return container
        }
        return makeInMemoryContainer()
    }

    static func makeInMemoryContainer() -> ModelContainer {
        // An in-memory store has no file to fail on; if even this throws,
        // SwiftData itself is unusable and there is nothing to fall back to.
        try! ModelContainer(
            for: schema,
            configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        )
    }

    private static func openContainer(userId: String) throws -> ModelContainer {
        var storeDirectory = directory(forUserId: userId)
        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try? storeDirectory.setResourceValues(resourceValues)

        let configuration = ModelConfiguration(
            schema: schema,
            url: storeDirectory.appending(path: "Checkins.store")
        )
        return try ModelContainer(for: schema, configurations: configuration)
    }

    /// Deletes every other account's history, and this account's on any
    /// other server. Run whenever a user's store is opened, which also sweeps
    /// up anything a crash kept sign-out from deleting.
    static func removeDatabases(except userId: String) {
        let keptDirectoryName = directoryName(forUserId: userId)
        let fileManager = FileManager.default
        guard let directories = try? fileManager.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: nil
        ) else {
            return
        }
        for directory in directories where directory.lastPathComponent != keptDirectoryName {
            try? fileManager.removeItem(at: directory)
        }
    }

    /// Called on sign-out. SQLite tolerates its files being unlinked while
    /// the outgoing container is still open; that container is released as
    /// soon as the signed-in UI finishes tearing down.
    static func removeAllDatabases() {
        try? FileManager.default.removeItem(at: rootDirectory)
    }
}
