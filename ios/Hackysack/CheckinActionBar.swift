//
//  CheckinActionBar.swift
//  Hackysack
//

import SwiftUI

/// The heart and speech bubble under a checkin, with the counts beneath
/// them. The heart talks to the social store itself, so rows only need to
/// say what a tap on the bubble opens.
struct CheckinActionBar: View {
    let checkin: Checkin
    let onComment: () -> Void

    @Environment(CheckinSocialStore.self) private var socialStore

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 2) {
                Button {
                    Task {
                        do {
                            try await socialStore.toggleLike(checkin)
                        } catch {
                            // The heart has already flipped back; nothing to add.
                            DevLog.network("Couldn't change like: \(error)")
                        }
                    }
                } label: {
                    Image(systemName: checkin.likedByMe ? "heart.fill" : "heart")
                        .foregroundStyle(checkin.likedByMe ? Color.red : Color.primary)
                        .contentTransition(.symbolEffect(.replace))
                        .symbolEffect(.bounce, value: checkin.likedByMe)
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(checkin.likedByMe ? "Unlike" : "Like")

                Button(action: onComment) {
                    Image(systemName: "bubble.right")
                        .foregroundStyle(Color.primary)
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Comment")
                .accessibilityHint("Shows the comments")
            }
            .font(.title3)
            // Plain, so inside a List the two icons are separate tap targets.
            .buttonStyle(.plain)
            // Pulls the glyphs back in line with the text above them.
            .padding(.leading, -6)

            if checkin.likeCount > 0 {
                Text("^[\(checkin.likeCount) like](inflect: true)")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
            }

            if checkin.commentCount > 0 {
                Button(action: onComment) {
                    Text(checkin.commentCount == 1 ? "View 1 comment" : "View all \(checkin.commentCount) comments")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 24) {
        CheckinActionBar(checkin: .preview(), onComment: {})
        CheckinActionBar(checkin: .preview(likeCount: 1, commentCount: 1, likedByMe: true), onComment: {})
        CheckinActionBar(checkin: .preview(likeCount: 12, commentCount: 3), onComment: {})
    }
    .padding()
    .environment(CheckinSocialStore())
}
