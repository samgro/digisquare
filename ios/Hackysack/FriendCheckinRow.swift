//
//  FriendCheckinRow.swift
//  Hackysack
//

import SwiftUI

/// A checkin in the Friends feed, a friend's or your own. The avatar and name
/// open the friend's profile, the checkin itself opens its detail page, and
/// the bar under it likes and comments.
struct FriendCheckinRow: View {
    let item: FriendCheckin
    let onSelectUser: (UserSummary) -> Void
    var onSelect: (Checkin) -> Void = { _ in }
    var onComment: (Checkin) -> Void = { _ in }

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

            VStack(alignment: .leading, spacing: 2) {
                // The byline is its own button here rather than inside
                // CheckinDetailsRow, so the details can be a button too
                // without one nesting in the other.
                Button {
                    onSelectUser(item.user)
                } label: {
                    Text(item.user.displayName)
                        .font(.subheadline).fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Shows their profile")

                Button {
                    onSelect(item.checkin)
                } label: {
                    CheckinDetailsRow(checkin: item.checkin)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Shows the checkin")

                CheckinActionBar(checkin: item.checkin) {
                    onComment(item.checkin)
                }
                .padding(.top, 4)
            }
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    List {
        FriendCheckinRow(item: .preview(), onSelectUser: { _ in })
        FriendCheckinRow(
            item: FriendCheckin(
                checkin: .preview(message: nil, primaryType: "park", minutesAgo: 90, likeCount: 2, commentCount: 5, likedByMe: true),
                user: UserSummary(id: "alex", name: "Alex Rivera", avatarURL: nil)
            ),
            onSelectUser: { _ in }
        )
    }
    .listStyle(.plain)
    .environment(CheckinSocialStore())
}
