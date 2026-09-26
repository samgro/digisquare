//
//  APIServerPicker.swift
//  Hackysack
//

import SwiftUI

#if targetEnvironment(simulator)

/// Switches a simulator build between the local dev server and production.
/// Each server keeps its own sign-in, so switching lands on whichever session
/// that server already has, or on the welcome screen.
struct APIServerPicker: View {
    @Environment(AuthManager.self) private var authManager
    @EnvironmentObject private var checkinStore: CheckinStore

    var body: some View {
        Picker("API Server", selection: selectedServer) {
            ForEach(APIServer.allCases) { server in
                Text(server.title).tag(server)
            }
        }
        .pickerStyle(.segmented)
    }

    private var selectedServer: Binding<APIServer> {
        Binding {
            authManager.server
        } set: { server in
            // Cleared first, so the timeline never shows the last server's
            // checkins under the new server's account.
            checkinStore.resetTimeline()
            authManager.switchServer(to: server)
        }
    }
}

#Preview {
    APIServerPicker()
        .padding()
        .environment(AuthManager())
        .environmentObject(CheckinStore.inMemory())
}

#endif
