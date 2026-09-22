//
//  KeychainStore.swift
//  Hackysack
//

import Foundation
import Security

enum KeychainError: Error {
    case status(OSStatus)
    /// The device is locked and the item is unreadable right now. Distinct
    /// from "no item": the caller must NOT treat this as being signed out.
    case interactionNotAllowed
}

// nonisolated because the target defaults to @MainActor isolation, which
// would otherwise put these on the main actor and make them unreachable from
// the AuthSessionStore actor. The Security framework calls below are
// synchronous and thread-safe, so they belong on whatever actor calls them.
nonisolated enum KeychainStore {
    private static let service = "samgro.Hackysack.auth"
    private static let account = "session"

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    static func save(_ credentials: StoredCredentials) throws {
        let data = try JSONEncoder().encode(credentials)

        let attributes: [String: Any] = [
            kSecValueData as String: data,
            // AfterFirstUnlock rather than WhenUnlocked because
            // LocationManager monitors visits and will eventually post a
            // checkin from a background callback on a locked device — a
            // WhenUnlocked item would be unreadable exactly then.
            //
            // ThisDeviceOnly because the other variants ride along in
            // encrypted backups, and a refresh token restored onto a second
            // device is a leaked credential.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainError.status(updateStatus)
        }

        var addQuery = baseQuery
        addQuery.merge(attributes) { current, _ in current }
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainError.status(addStatus)
        }
    }

    /// Returns nil when there is genuinely no stored session. Throws
    /// `.interactionNotAllowed` when the device is locked, so the caller can
    /// wait rather than concluding the user is signed out and deleting the
    /// item.
    static func load() throws -> StoredCredentials? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { return nil }
            // A decode failure means the stored shape changed under us, e.g.
            // after an update that altered UserProfile. Treat it as "no
            // session" and make the user sign in again rather than crashing.
            return try? JSONDecoder().decode(StoredCredentials.self, from: data)
        case errSecItemNotFound:
            return nil
        case errSecInteractionNotAllowed:
            throw KeychainError.interactionNotAllowed
        default:
            throw KeychainError.status(status)
        }
    }

    static func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.status(status)
        }
    }
}
