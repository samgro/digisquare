//
//  ContentView.swift
//  Digisquare
//
//  Created by Sam Grossberg on 9/18/26.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var locationManager = LocationManager()
    @StateObject private var checkinStore = CheckinStore()
    @Environment(\.scenePhase) private var scenePhase

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
        }
        .environmentObject(locationManager)
        .environmentObject(checkinStore)
        .onAppear {
            locationManager.requestPermissionsIfNeeded()
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                locationManager.startUpdatingLocation()
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
}
