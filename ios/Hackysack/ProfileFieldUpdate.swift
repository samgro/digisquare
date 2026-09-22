//
//  ProfileFieldUpdate.swift
//  Hackysack
//

import Foundation

/// One field of a profile PATCH.
///
/// The three cases are genuinely distinct on the wire, and a plain `String?`
/// cannot express them: Swift's synthesized encoder omits nil, so there would
/// be no way to say "clear this field".
///
///   - `unchanged` omits the key entirely, and the server leaves the column as it is
///   - `clear` sends an explicit null, and the server sets the column to null
///   - `value` sends the new value
enum ProfileFieldUpdate {
    case unchanged
    case clear
    case value(String)

    /// Collapses an optional into `value` or `clear` — for a field the user is
    /// definitely editing, where "leave it alone" is not one of the outcomes.
    static func editing(_ text: String?) -> ProfileFieldUpdate {
        guard let text, !text.isEmpty else { return .clear }
        return .value(text)
    }

    func encode<Key: CodingKey>(
        into container: inout KeyedEncodingContainer<Key>,
        forKey key: Key
    ) throws {
        switch self {
        case .unchanged:
            break
        case .clear:
            try container.encodeNil(forKey: key)
        case .value(let text):
            try container.encode(text, forKey: key)
        }
    }
}
