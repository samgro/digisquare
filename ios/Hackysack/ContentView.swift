//
//  ContentView.swift
//  Hackysack
//
//  Created by Sam Grossberg on 9/18/26.
//

import SwiftData
import SwiftUI

struct ContentView: View {
    @Environment(AuthManager.self) private var authManager
    // Owned by the app delegate, which Core Location can launch without a
    // scene to deliver a visit.
    @Environment(LocationManager.self) private var locationManager
    @EnvironmentObject private var checkinStore: CheckinStore
    /// The signed-in user's local checkin history. Created once their id is
    /// known and replaced if the account changes underneath this view.
    @State private var historySync: CheckinHistorySync?
    @State private var friendsStore = FriendsStore()
    @State private var notificationsStore = NotificationsStore()
    @State private var socialStore = CheckinSocialStore()
    @State private var swarmImportStore = SwarmImportStore()
    @Environment(\.scenePhase) private var scenePhase

    /// The signed-in user's id, or nil while signing in. ContentView only
    /// appears behind the auth gate, so in practice this is always set.
    private var signedInUserId: String? { authManager.currentProfile?.id }

    var body: some View {
        // A ZStack rather than a Group: modifiers on a Group apply to each
        // branch separately, so swapping the spinner for the tabs would
        // restart the sync task below.
        ZStack {
            if let historySync {
                tabs
                    .environment(historySync)
                    .modelContainer(historySync.container)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .environment(friendsStore)
        .environment(notificationsStore)
        .environment(socialStore)
        .environment(swarmImportStore)
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
            connectSwarmImportStore()
            Task { await notificationsStore.refreshUnreadCount() }
            Task { await swarmImportStore.refresh() }
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
            swarmImportStore = SwarmImportStore()
            connectSocialStore()
            connectSwarmImportStore()
            Task { await notificationsStore.refreshUnreadCount() }
            Task { await swarmImportStore.refresh() }
        }
        .task(id: signedInUserId) {
            // Runs at sign-in and at every launch with a saved session, and
            // keeps the local history in sync, silently, for as long as the
            // user stays signed in.
            guard let signedInUserId else { return }
            let historySync = CheckinHistorySync(
                container: CheckinDatabase.makeContainer(userId: signedInUserId)
            )
            self.historySync = historySync
            checkinStore.historySync = historySync
            await historySync.run()
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                locationManager.startUpdatingLocation()
                // Suggestions made while the app was in the background are
                // already in the store; this picks up anything checked in or
                // edited on another device, and new likes and comments.
                historySync?.requestSync()
                // Keeps the bell badge current when coming back to the app;
                // likes, comments and requests arrive while it's in the background.
                Task { await notificationsStore.refreshUnreadCount() }
                // An import keeps running on the server while the app is away.
                Task { await swarmImportStore.refresh() }
            case .background:
                locationManager.stopUpdatingLocation()
            case .inactive:
                break
            @unknown default:
                break
            }
        }
    }

    private var tabs: some View {
        TabView {
            Tab("Timeline", systemImage: Glyphs.timelineTab) {
                TimelineView()
            }
            Tab("Friends", systemImage: Glyphs.friendsTab) {
                FriendsView()
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

    /// A finished import means thousands of new rows: the local history
    /// syncs them down and the friends feed reloads.
    private func connectSwarmImportStore() {
        let checkinStore = checkinStore
        let friendsStore = friendsStore
        swarmImportStore.onImportFinished = {
            checkinStore.historySync?.requestSync()
            Task { await friendsStore.loadFeed() }
        }
    }
}

#Preview {
    ContentView()
        .environment(AuthManager())
        .environment(LocationManager())
        .environmentObject(CheckinStore.inMemory())
}
