//
//  ProfileView.swift
//  Hackysack
//

import SwiftUI

struct ProfileView: View {
    @Environment(AuthManager.self) private var authManager
    @Environment(FriendsStore.self) private var friendsStore

    @State private var isEditing = false
    @State private var isShowingFriendRequests = false
    @State private var isConfirmingSignOut = false
    @State private var didFailToRefresh = false

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
                    profileList(profile)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Profile")
            .toolbar {
                if profile != nil {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Edit") { isEditing = true }
                    }
                }
            }
            .sheet(isPresented: $isEditing) {
                EditProfileView()
            }
            .fullScreenCover(isPresented: $isShowingFriendRequests) {
                FriendRequestsView()
            }
        }
    }

    private func profileList(_ profile: UserProfile) -> some View {
        List {
            Section {
                VStack(spacing: HackysackSpacing.medium) {
                    AvatarView(
                        url: profile.avatarURL,
                        initials: profile.initials,
                        size: HackysackSize.avatarLarge
                    )

                    Text(profile.name ?? "\(AppInfo.name) member")
                        .font(.title2.bold())

                    if let bio = profile.bio, !bio.isEmpty {
                        Text(bio)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, HackysackSpacing.large)
                    } else {
                        Button("Add a bio") { isEditing = true }
                            .font(.subheadline)
                    }

                    if didFailToRefresh {
                        // The cached profile is still on screen and still
                        // correct. Replacing it with an error state would be a
                        // downgrade, so this is only a quiet note.
                        Text("Couldn't refresh")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, HackysackSpacing.large)
            }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)

            // Directly under the header, where it's the first thing seen
            // after tapping the badged tab, and gone entirely when there is
            // nothing to review.
            if !friendsStore.incomingRequests.isEmpty {
                Section {
                    Button {
                        isShowingFriendRequests = true
                    } label: {
                        FriendRequestsBanner(requests: friendsStore.incomingRequests)
                    }
                }
            }

            Section("Account") {
                // An Apple user who hid their address, or one created by the
                // email-collision path, genuinely has no email. Saying so
                // reads better than an empty row that looks like a bug.
                LabeledContent("Email", value: profile.email ?? "Hidden by Apple")
                LabeledContent("Sign-in method", value: profile.signInMethodDescription)
                LabeledContent(
                    "Member since",
                    value: profile.createdAt.formatted(.dateTime.month(.wide).year())
                )
            }

            Section {
                Button("Sign Out", role: .destructive) {
                    isConfirmingSignOut = true
                }
                // Attached to the button rather than the List: on iOS 26 the
                // dialog presents as a popover anchored to this view, so the
                // arrow points at whatever it hangs off.
                .confirmationDialog(
                    "Sign out of \(AppInfo.name)?",
                    isPresented: $isConfirmingSignOut,
                    titleVisibility: .visible
                ) {
                    Button("Sign Out", role: .destructive) {
                        Task { await authManager.signOut() }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    // Worth spelling out while there is no password reset: signing out
                    // of a password account is not cheaply reversible if the password
                    // has been forgotten.
                    Text("You'll need your email and password to sign back in.")
                }
            } footer: {
                Text("\(AppInfo.name) \(Self.appVersion) (\(Self.buildNumber))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.insetGrouped)
        .animation(.default, value: friendsStore.incomingRequests.isEmpty)
        .refreshable {
            await friendsStore.loadRequests()
            await authManager.refreshProfile()
            didFailToRefresh = authManager.lastError != nil
        }
    }

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    private static var buildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    }
}

#Preview {
    ProfileView()
        .environment(AuthManager())
        .environment(FriendsStore())
}
