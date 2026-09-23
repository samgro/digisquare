//
//  FriendCheckinRow.swift
//  Hackysack
//

import SwiftUI

/// A checkin in the Friends feed, a friend's or your own. The avatar and name both open the
/// friend's profile; the rest of the row is not a button.
struct FriendCheckinRow: View {
    let item: FriendCheckin
    let onSelectUser: (UserSummary) -> Void

    /// Read only so the row redraws when the text size changes, which moves
    /// the name's cap height and so where the avatar should sit.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        // Aligned on the name's baseline, then the avatar is lowered so its
        // top meets the top of the name's capitals rather than the taller
        // top of the text line, which sits above them.
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Button {
                onSelectUser(item.user)
            } label: {
                AvatarView(url: item.user.avatarURL, initials: item.user.initials)
            }
            // Plain, so inside a List the avatar and name are separate tap
            // targets instead of the whole row firing the first button.
            .buttonStyle(.plain)
            .alignmentGuide(.firstTextBaseline) { dimensions in
                dimensions[.top] + UIFont.preferredFont(forTextStyle: .subheadline).capHeight
            }
            .accessibilityLabel(item.user.displayName)
            .accessibilityHint("Shows their profile")

            CheckinDetailsRow(
                checkin: item.checkin,
                personName: item.user.displayName,
                onPersonTap: { onSelectUser(item.user) }
            )
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    List {
        FriendCheckinRow(item: .preview(), onSelectUser: { _ in })
        FriendCheckinRow(
            item: FriendCheckin(
                checkin: .preview(message: nil, primaryType: "park", minutesAgo: 90),
                user: UserSummary(id: "alex", name: "Alex Rivera", avatarURL: nil)
            ),
            onSelectUser: { _ in }
        )
    }
    .listStyle(.plain)
}
