//
//  FriendsView.swift
//  Digisquare
//

import SwiftUI

struct FriendsView: View {
    @EnvironmentObject private var checkinStore: CheckinStore

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottomTrailing) {
                content
                CheckInFAB()
            }
            .navigationTitle("Friends")
            .task {
                await checkinStore.loadFriends()
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if !checkinStore.friendsCheckins.isEmpty {
            List(checkinStore.friendsCheckins) { checkin in
                FriendCheckinRow(checkin: checkin)
            }
            .listStyle(.plain)
            .animation(.default, value: checkinStore.friendsCheckins)
            .refreshable {
                await checkinStore.loadFriends()
            }
        } else if !checkinStore.hasLoadedFriends {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let friendsError = checkinStore.friendsError {
            ContentUnavailableView {
                Label("Couldn't Load Check-ins", systemImage: "exclamationmark.triangle")
            } description: {
                Text(friendsError)
            } actions: {
                Button("Try Again") {
                    Task { await checkinStore.loadFriends() }
                }
            }
        } else {
            ContentUnavailableView(
                "Nothing Here Yet",
                systemImage: "person.2",
                description: Text("Check-ins from everyone will show up here.")
            )
        }
    }
}

#Preview {
    FriendsView()
        .environmentObject(LocationManager())
        .environmentObject(CheckinStore())
}
