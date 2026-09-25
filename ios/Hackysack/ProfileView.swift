//
//  ProfileView.swift
//  Hackysack
//

import SwiftUI

/// Your own profile, pushed from the avatar in the Timeline and Friends bars.
/// It is your profile exactly as friends see it, which is UserProfileView
/// with Edit Profile in place of friend actions, plus a Settings button,
/// where account details and sign out live.
struct ProfileView: View {
    @Environment(AuthManager.self) private var authManager

    var body: some View {
        Group {
            if let profile = authManager.currentProfile {
                UserProfileView(user: profile.summary)
            } else {
                ProgressView()
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    SettingsView()
                } label: {
                    Label("Settings", systemImage: Glyphs.settings)
                }
            }
        }
    }
}

#Preview {
    NavigationStack {
        ProfileView()
    }
    .environment(AuthManager())
    .environment(FriendsStore())
    .environment(LocationManager())
    .environment(CheckinSocialStore())
    .environmentObject(CheckinStore.inMemory())
}
