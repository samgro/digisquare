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
    @State private var authManager = AuthManager()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(authManager)
                .environment(appDelegate.locationManager)
                .environmentObject(appDelegate.checkinStore)
                .animation(.easeInOut(duration: 0.25), value: authManager.state)
        }
    }
}
