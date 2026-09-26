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
    @Environment(SwarmImportStore.self) private var swarmImportStore

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
            // First: for most people it is the one thing here they came to do.
            Section {
                NavigationLink {
                    SwarmImportView()
                } label: {
                    HStack(spacing: 12) {
                        Text("🐝")
                            .font(.title3)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Import your Swarm checkins")
                            if let swarmStatus {
                                Text(swarmStatus)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

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

            #if targetEnvironment(simulator)
            Section {
                APIServerPicker()
            } header: {
                Text("API Server")
            } footer: {
                Text("Each server keeps its own sign-in.")
            }
            #endif

            #if DEBUG
            Section("Debug") {
                DebugVisitMenu()
            }
            #endif

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

    /// "Connected · importing" or "Connected · 3,812 checkins"; nothing until
    /// Swarm is connected, when the row speaks for itself.
    private var swarmStatus: String? {
        guard swarmImportStore.isConnected else { return nil }
        guard let latestImport = swarmImportStore.latestImport else { return "Connected" }
        switch latestImport.status {
        case .running: return "Connected · importing"
        case .failed: return "Connected · last import stopped"
        case .completed: return "Connected · \(latestImport.progressDetail)"
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
    NavigationStack {
        SettingsView()
            .environment(AuthManager())
            .environment(SwarmImportStore())
            .environment(LocationManager())
            .environmentObject(CheckinStore.inMemory())
    }
}
