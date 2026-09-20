//
//  FriendCheckinRow.swift
//  Digisquare
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

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(checkin.userId)
                        .font(.headline)
                    Spacer(minLength: 0)
                    Text(checkin.createdAt, format: .relative(presentation: .named))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                (Text("checked in at ").foregroundStyle(.secondary)
                    + Text(checkin.placeName).fontWeight(.semibold))
                    .font(.subheadline)

                if let message = checkin.message {
                    Text(message)
                        .font(.body)
                }
            }
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
