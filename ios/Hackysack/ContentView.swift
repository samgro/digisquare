//
//  ContentView.swift
//  Hackysack
//
//  Created by Sam Grossberg on 9/18/26.
//

import SwiftUI

struct ContentView: View {
    @Environment(AuthManager.self) private var authManager
    @State private var locationManager = LocationManager()
    @StateObject private var checkinStore = CheckinStore()
    @State private var friendsStore = FriendsStore()
    @Environment(\.scenePhase) private var scenePhase

    /// The signed-in user's id, or nil while signing in. ContentView only
    /// appears behind the auth gate, so in practice this is always set.
    private var signedInUserId: String? {
        switch authManager.state {
        case .signedIn(let profile), .needsProfileSetup(let profile):
            return profile.id
        case .launching, .signedOut:
            return nil
        }
    }

    var body: some View {
        TabView {
            Tab("Timeline", systemImage: "clock") {
                TimelineView()
            }
            Tab("Friends", systemImage: "person.2") {
                FriendsView()
            }
            Tab("Profile", systemImage: "person.crop.circle") {
                ProfileView()
            }
            // Zero hides the badge.
            .badge(friendsStore.pendingRequestCount)
        }
        .environment(locationManager)
        .environment(friendsStore)
        .environmentObject(checkinStore)
        .onAppear {
            locationManager.requestPermissionsIfNeeded()
            // The scenePhase observer below only fires on a change. After
            // sign-in this view appears while the scene is already active, so
            // without this nothing would ever start location updates.
            if scenePhase == .active {
                locationManager.startUpdatingLocation()
            }
            checkinStore.currentUserId = signedInUserId
            Task { await friendsStore.loadRequests() }
        }
        .onChange(of: signedInUserId) { _, newUserId in
            // Keeps the timeline pointed at the right account if the signed-in
            // user changes underneath this view.
            checkinStore.currentUserId = newUserId
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                locationManager.startUpdatingLocation()
                // Keeps the Profile badge current when coming back to the
                // app; requests arrive while it's in the background.
                Task { await friendsStore.loadRequests() }
            case .background:
                locationManager.stopUpdatingLocation()
            case .inactive:
                break
            @unknown default:
                break
            }
        }
    }
}

#Preview {
    ContentView()
        .environment(AuthManager())
}
