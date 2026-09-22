//
//  HackysackApp.swift
//  Hackysack
//
//  Created by Sam Grossberg on 9/18/26.
//

import SwiftUI

@main
struct HackysackApp: App {
    @State private var authManager = AuthManager()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(authManager)
                .animation(.easeInOut(duration: 0.25), value: authManager.state)
        }
    }
}
