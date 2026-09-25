//
//  CheckinPrivacyToggle.swift
//  Hackysack
//

import SwiftUI

/// A capsule that flips a checkin between friends and private. Used in the
/// compose screen's options row and in the sheet for editing a suggested checkin.
struct CheckinPrivacyToggle: View {
    @Binding var visibility: CheckinVisibility

    var body: some View {
        Button {
            withAnimation(.snappy) {
                visibility.toggle()
            }
        } label: {
            Label(
                visibility.isPrivate ? "Private" : "Friends",
                systemImage: visibility.isPrivate ? Glyphs.privateCheckin : Glyphs.friendsCheckin
            )
            .font(.subheadline.weight(.medium))
            .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .tint(visibility.isPrivate ? .gray : .blue)
        .accessibilityLabel("Checkin visibility")
        .accessibilityValue(visibility.isPrivate ? "Private" : "Friends")
        .accessibilityHint(visibility.isPrivate ? "Double tap to share with friends" : "Double tap to keep it to yourself")
    }
}

#Preview {
    @Previewable @State var visibility: CheckinVisibility = .friends
    VStack(spacing: 16) {
        CheckinPrivacyToggle(visibility: $visibility)
        CheckinPrivacyToggle(visibility: $visibility)
            .controlSize(.small)
    }
    .padding()
}
