//
//  FriendCheckinRow.swift
//  Hackysack
//

import SwiftUI

/// A friend's checkin in the Friends feed. The avatar and name both open the
/// friend's profile; the rest of the row is not a button.
struct FriendCheckinRow: View {
    let item: FriendCheckin
    let onSelectUser: (UserSummary) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button {
                onSelectUser(item.user)
            } label: {
                AvatarView(url: item.user.avatarURL, initials: item.user.initials)
            }
            // Plain, so inside a List the avatar and name are separate tap
            // targets instead of the whole row firing the first button.
            .buttonStyle(.plain)
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
