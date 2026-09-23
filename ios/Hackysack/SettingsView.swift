//
//  SettingsView.swift
//  Hackysack
//

import SwiftUI

/// Account details and sign out, behind the gear on Profile. The profile
/// itself is the face shown to friends; nothing here is anyone else's
/// business, so it lives a level down.
struct SettingsView: View {
    @Environment(AuthManager.self) private var authManager

    @State private var isConfirmingSignOut = false

    private var profile: UserProfile? {
        switch authManager.state {
        case .signedIn(let profile), .needsProfileSetup(let profile):
            return profile
        case .launching, .signedOut:
            return nil
        }
    }

    var body: some View {
        List {
            if let profile {
                Section("Account") {
                    // An Apple user who hid their address, or one created by
                    // the email-collision path, genuinely has no email. Saying
                    // so reads better than an empty row that looks like a bug.
                    LabeledContent(
                        "Email",
                        value: profile.email ?? (profile.hasAppleSignIn ? "Hidden by Apple" : "None")
                    )
                    LabeledContent("Sign-in method", value: profile.signInMethodDescription)
                    LabeledContent(
                        "Member since",
                        value: profile.createdAt.formatted(.dateTime.month(.wide).year())
                    )
                }
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
                }
            } footer: {
                Text("\(AppInfo.name) \(Self.appVersion) (\(Self.buildNumber))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
    }

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    private static var buildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    }
}

#Preview {
    NavigationStack {
        SettingsView()
            .environment(AuthManager())
    }
}
