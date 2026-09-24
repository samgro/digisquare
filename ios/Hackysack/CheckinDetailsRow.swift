//
//  CheckinDetailsRow.swift
//  Hackysack
//

import SwiftUI

/// The content shared by every place a checkin is shown: the place name as
/// the title, its category/neighborhood/city, and when it happened — used by
/// both the timeline and friends feed so the two stay visually identical.
struct CheckinDetailsRow: View {
    let checkin: Checkin
    /// A small byline above the place name. `nil` on the timeline, where
    /// every row is already known to be the current user's own checkin.
    var personName: String? = nil
    /// Makes the byline a button, for opening that person's profile.
    var onPersonTap: (() -> Void)? = nil
    /// Off on the timeline, where day headers already say the date.
    var showsDate = true
    /// One on a suggestion, where the buttons beside the row would otherwise
    /// wrap most names; the full name is in the edit sheet.
    var placeNameLineLimit = 2

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let personName {
                if let onPersonTap {
                    // Plain, so inside a List only the name itself is the tap
                    // target rather than the whole row.
                    Button(action: onPersonTap) {
                        Text(personName)
                            .font(.subheadline).fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Shows their profile")
                } else {
                    Text(personName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Text(checkin.placeName)
                .font(.headline)
                .lineLimit(placeNameLineLimit)

            if let detailLine {
                Text(detailLine)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 4) {
                Text(dateLine)
                if checkin.visibility.isPrivate {
                    Image(systemName: "lock.fill")
                        .font(.caption)
                        .accessibilityLabel("Private")
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)

            if let message = checkin.message {
                Text(message)
                    .font(.body)
                    .padding(.top, 2)
            }
        }
    }

    /// "Coffee Shop · Sacramento, CA", or whichever of category/locality is
    /// available, or `nil` when neither is.
    private var detailLine: String? {
        let category = checkin.placePrimaryType.map { PlaceTypeSymbol.displayName(for: $0) }
        let parts = [category, checkin.locality].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var dateLine: String {
        showsDate ? checkin.formattedCheckinDateAndTime : checkin.formattedCheckinTime
    }
}

#Preview("Friend") {
    List {
        CheckinDetailsRow(checkin: .preview(), personName: "sam")
        CheckinDetailsRow(
            checkin: .preview(userId: "alex", message: nil, primaryType: "park", minutesAgo: 90),
            personName: "alex"
        )
    }
    .listStyle(.plain)
}

#Preview("Timeline") {
    List {
        CheckinDetailsRow(checkin: .preview(), showsDate: false)
        CheckinDetailsRow(checkin: .preview(message: nil, primaryType: "park"), showsDate: false)
        CheckinDetailsRow(checkin: .preview(message: "Just me", visibility: .onlyMe), showsDate: false)
    }
    .listStyle(.plain)
}
