//
//  FriendCheckinRow.swift
//  Hackysack
//

import SwiftUI

struct UserAvatarView: View {
    let userId: String

    var body: some View {
        Text(String(userId.prefix(1)).uppercased())
            .font(.headline)
            .foregroundStyle(.white)
            .frame(width: 36, height: 36)
            .background(Circle().fill(Color.blue))
    }
}

struct FriendCheckinRow: View {
    let checkin: Checkin

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            UserAvatarView(userId: checkin.userId)
            CheckinDetailsRow(checkin: checkin, personName: checkin.userId)
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    List {
        FriendCheckinRow(checkin: .preview())
        FriendCheckinRow(checkin: .preview(userId: "alex", message: nil, primaryType: "park", minutesAgo: 90))
    }
    .listStyle(.plain)
}
