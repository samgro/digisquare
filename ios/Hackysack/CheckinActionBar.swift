//
//  CheckinActionBar.swift
//  Hackysack
//

import SwiftUI

/// The heart and speech bubble under a checkin, each with its count beside
/// it. The heart talks to the social store itself, so rows only need to say
/// what a tap on the bubble opens.
struct CheckinActionBar: View {
    let checkin: Checkin
    let onComment: () -> Void

    @Environment(CheckinSocialStore.self) private var socialStore

    var body: some View {
        HStack(spacing: 16) {
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
                ActionBarLabel(systemImage: checkin.likedByMe ? "heart.fill" : "heart", count: checkin.likeCount) { heart in
                    heart
                        // Secondary like the text above it, red once liked.
                        .foregroundStyle(checkin.likedByMe ? AnyShapeStyle(Color.red) : AnyShapeStyle(.secondary))
                        .contentTransition(.symbolEffect(.replace))
                        .symbolEffect(.bounce, value: checkin.likedByMe)
                }
            }
            .accessibilityLabel(checkin.likedByMe ? "Unlike" : "Like")
            .accessibilityValue("^[\(checkin.likeCount) like](inflect: true)")

            Button(action: onComment) {
                ActionBarLabel(systemImage: "bubble.right", count: checkin.commentCount) { $0 }
            }
            .accessibilityLabel("Comment")
            .accessibilityValue("^[\(checkin.commentCount) comment](inflect: true)")
            .accessibilityHint("Shows the comments")
        }
        .foregroundStyle(.secondary)
        // Plain, so inside a List the two buttons are separate tap targets.
        .buttonStyle(.plain)
    }
}

/// A glyph with its count to the right, which is left out at zero. The tap
/// target reaches above and below the glyph without taking up any room, so
/// the bar sits right under the text above it.
private struct ActionBarLabel<Glyph: View>: View {
    let systemImage: String
    let count: Int
    @ViewBuilder let styleGlyph: (Image) -> Glyph

    var body: some View {
        HStack(spacing: 4) {
            styleGlyph(Image(systemName: systemImage))
                .font(.title3)
            if count > 0 {
                Text(count, format: .number)
                    .font(.subheadline)
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(count)))
            }
        }
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .padding(.vertical, -7)
        .animation(.default, value: count)
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
