//
//  FriendsView.swift
//  Hackysack
//

import SwiftUI

struct FriendsView: View {
    @Environment(FriendsStore.self) private var friendsStore

    @State private var isAddingFriends = false
    @State private var selectedUser: UserSummary?

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottomTrailing) {
                content
                CheckInFAB()
            }
            .navigationTitle("Friends")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isAddingFriends = true
                    } label: {
                        Label("Add Friends", systemImage: "person.badge.plus")
                    }
                }
            }
            .sheet(isPresented: $isAddingFriends) {
                AddFriendsView()
            }
            .sheet(item: $selectedUser) { user in
                UserProfileSheet(user: user)
            }
            .task {
                await friendsStore.loadFeed()
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if !friendsStore.feed.isEmpty {
            List(friendsStore.feed) { item in
                FriendCheckinRow(item: item) { user in
                    selectedUser = user
                }
            }
            .listStyle(.plain)
            .animation(.default, value: friendsStore.feed)
            .refreshable {
                await friendsStore.loadFeed()
            }
        } else if !friendsStore.hasLoadedFeed {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let feedError = friendsStore.feedError {
            ContentUnavailableView {
                Label("Couldn't Load Checkins", systemImage: "exclamationmark.triangle")
            } description: {
                Text(feedError)
            } actions: {
                Button("Try Again") {
                    Task { await friendsStore.loadFeed() }
                }
            }
        } else if friendsStore.friends.isEmpty {
            ContentUnavailableView {
                Label("No Friends Yet", systemImage: "person.2")
            } description: {
                Text("Find people you know to see where they check in.")
            } actions: {
                Button("Find Friends") {
                    isAddingFriends = true
                }
                .buttonStyle(.borderedProminent)
            }
        } else {
            ContentUnavailableView(
                "Nothing Here Yet",
                systemImage: "person.2",
                description: Text("Checkins from your friends will show up here.")
            )
        }
    }
}

#Preview {
    FriendsView()
        .environment(LocationManager())
        .environment(FriendsStore())
        .environment(AuthManager())
        .environmentObject(CheckinStore())
}
