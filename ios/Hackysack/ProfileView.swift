//
//  ProfileView.swift
//  Hackysack
//

import SwiftUI

/// The Profile tab: your own profile exactly as friends see it, which is
/// UserProfileView with Edit Profile in place of friend actions. The tab adds
/// only the Settings button, where account details and sign out live.
struct ProfileView: View {
    @Environment(AuthManager.self) private var authManager

    private var profile: UserProfile? {
        switch authManager.state {
        case .signedIn(let profile), .needsProfileSetup(let profile):
            return profile
        case .launching, .signedOut:
            return nil
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let profile {
                    UserProfileView(
                        user: UserSummary(id: profile.id, name: profile.name, avatarURL: profile.avatarURL)
                    )
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
}

#Preview {
    ProfileView()
        .environment(AuthManager())
        .environment(FriendsStore())
        .environment(LocationManager())
        .environmentObject(CheckinStore.inMemory())
}
