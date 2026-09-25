//
//  ContentView.swift
//  Hackysack
//
//  Created by Sam Grossberg on 9/18/26.
//

import SwiftUI

struct ContentView: View {
    @Environment(AuthManager.self) private var authManager
    // Owned by the app delegate, which Core Location can launch without a
    // scene to deliver a visit.
    @Environment(LocationManager.self) private var locationManager
    @EnvironmentObject private var checkinStore: CheckinStore
    @State private var friendsStore = FriendsStore()
    @State private var notificationsStore = NotificationsStore()
    @State private var socialStore = CheckinSocialStore()
    @Environment(\.scenePhase) private var scenePhase

    /// The signed-in user's id, or nil while signing in. ContentView only
    /// appears behind the auth gate, so in practice this is always set.
    private var signedInUserId: String? { authManager.currentProfile?.id }

    var body: some View {
        TabView {
            Tab("Timeline", systemImage: Glyphs.timelineTab) {
                TimelineView()
            }
            Tab("Friends", systemImage: Glyphs.friendsTab) {
                FriendsView()
            }
        }
        .environment(friendsStore)
        .environment(notificationsStore)
        .environment(socialStore)
        .onAppear {
            locationManager.requestPermissionsIfNeeded()
            // The scenePhase observer below only fires on a change. After
            // sign-in this view appears while the scene is already active, so
            // without this nothing would ever start location updates.
            if scenePhase == .active {
                locationManager.startUpdatingLocation()
            }
            checkinStore.currentUserId = signedInUserId
            connectSocialStore()
            Task { await notificationsStore.refreshUnreadCount() }
        }
        .onChange(of: signedInUserId) { _, newUserId in
            // Keeps the timeline pointed at the right account if the signed-in
            // user changes underneath this view.
            checkinStore.currentUserId = newUserId
            // Fresh stores, so the bell and the Friends feed never show the
            // previous account's notifications or friends.
            friendsStore = FriendsStore()
            notificationsStore = NotificationsStore()
            socialStore = CheckinSocialStore()
            connectSocialStore()
            Task { await notificationsStore.refreshUnreadCount() }
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                locationManager.startUpdatingLocation()
                // Suggestions made while the app was in the background are
                // already in the store; this picks up anything saved from
                // another device.
                if checkinStore.hasLoadedTimeline {
                    Task { await checkinStore.loadTimeline() }
                }
                // Keeps the bell badge current when coming back to the app;
                // likes, comments and requests arrive while it's in the background.
                Task { await notificationsStore.refreshUnreadCount() }
            case .background:
                locationManager.stopUpdatingLocation()
            case .inactive:
                break
            @unknown default:
                break
            }
        }
    }

    /// Every like, comment or edit reaches both feeds' copies of the checkin.
    /// Re-run whenever the stores are replaced, so the closure never holds a
    /// store that has been thrown away.
    private func connectSocialStore() {
        let checkinStore = checkinStore
        let friendsStore = friendsStore
        socialStore.onCheckinChanged = { checkin in
            checkinStore.apply(checkin)
            friendsStore.apply(checkin)
        }
    }
}

#Preview {
    ContentView()
        .environment(AuthManager())
        .environment(LocationManager())
        .environmentObject(CheckinStore.inMemory())
}
