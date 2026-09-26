//
//  RootView.swift
//  Hackysack
//

import SwiftUI

/// Decides what the app shows based on whether anyone is signed in.
///
/// AuthManager reads the Keychain synchronously in its initializer, so by the
/// time this body first runs the state is already .signedIn or .signedOut. The
/// .launching branch is reached only when the device is still locked and the
/// Keychain is temporarily unreadable.
struct RootView: View {
    @Environment(AuthManager.self) private var authManager

    var body: some View {
        ZStack(alignment: .top) {
            content
            // Debug simulator builds only: the dev server has moved on to a
            // newer commit. A different branch is handled by WrongServerWindow.
            if BuildGate.shared.verdict == .commitDiffers,
               let app = BuildGate.shared.app,
               let server = BuildGate.shared.server {
                BuildMismatchBanner(app: app, server: server)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch authManager.state {
        case .launching:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(.systemBackground))

        case .signedOut:
            WelcomeView()
                .transition(.opacity)

        case .needsProfileSetup:
            // Every new account lands here, because none has a hometown yet,
            // as does anyone Apple withheld a name for.
            EditProfileView(purpose: .setup)
                .transition(.opacity)

        case .signedIn:
            ContentView()
                .transition(.opacity)
        }
    }
}

#Preview {
    RootView()
        .environment(AuthManager())
        .environment(LocationManager())
        .environmentObject(CheckinStore.inMemory())
}
