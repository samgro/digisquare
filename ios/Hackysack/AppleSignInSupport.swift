//
//  AppleSignInSupport.swift
//  Hackysack
//

import CryptoKit
import Foundation

enum AppleSignInSupport {
    /// A fresh random nonce per sign-in attempt.
    ///
    /// The raw value goes to our API; only its SHA-256 goes to Apple, which
    /// echoes that hash back inside the identity token. Comparing the two
    /// binds the token to this attempt so one cannot be replayed into another.
    static func randomNonce(length: Int = 32) -> String {
        precondition(length > 0)
        var randomBytes = [UInt8](repeating: 0, count: length)
        let status = SecRandomCopyBytes(kSecRandomDefault, length, &randomBytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed: \(status)")

        let allowedCharacters = Array(
            "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-._"
        )
        return String(randomBytes.map { allowedCharacters[Int($0) % allowedCharacters.count] })
    }

    static func sha256Hexadecimal(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
