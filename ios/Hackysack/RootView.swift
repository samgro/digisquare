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
