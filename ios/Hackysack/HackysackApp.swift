//
//  HackysackApp.swift
//  Hackysack
//
//  Created by Sam Grossberg on 9/18/26.
//

import SwiftUI

@main
struct HackysackApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var authManager = AuthManager()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(authManager)
                .environment(appDelegate.locationManager)
                .environmentObject(appDelegate.checkinStore)
                .animation(.easeInOut(duration: 0.25), value: authManager.state)
                // The dev server gate (Debug simulator builds only): ask the
                // server what it runs on launch and each return to the
                // foreground, and put up the block whenever the verdict says so.
                .task { await BuildGate.shared.check() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        Task { await BuildGate.shared.check() }
                    }
                }
                .onChange(of: BuildGate.shared.isBlocking, initial: true) { _, _ in
                    WrongServerWindow.sync(with: BuildGate.shared)
                }
        }
    }
}
