//
//  FriendsView.swift
//  Hackysack
//

import SwiftUI

struct FriendsView: View {
    @Environment(FriendsStore.self) private var friendsStore
    @EnvironmentObject private var checkinStore: CheckinStore

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
            .navigationDestination(item: $selectedUser) { user in
                UserProfileView(user: user)
            }
            .task {
                await friendsStore.loadFeed()
            }
            // Your own checkins are in the feed too, so one saved from the
            // button on this tab shows up without a pull to refresh.
            .onChange(of: newestSavedCheckinId) { _, _ in
                Task { await friendsStore.loadFeed() }
            }
        }
    }

    /// Separators only between rows, not above the first or below the last.
    private func outerSeparatorEdges(of item: FriendCheckin) -> VerticalEdge.Set {
        var edges: VerticalEdge.Set = []
        if item.id == friendsStore.feed.first?.id { edges.insert(.top) }
        if item.id == friendsStore.feed.last?.id { edges.insert(.bottom) }
        return edges
    }

    /// The timeline is newest first, so this changes when a checkin finishes
    /// saving rather than when it is first submitted with a placeholder.
    private var newestSavedCheckinId: String? {
        checkinStore.timelineEntries.first { $0.syncStatus == .saved }?.checkin.id
    }

    @ViewBuilder
    private var content: some View {
        if !friendsStore.feed.isEmpty {
            List {
                ForEach(friendsStore.feed) { item in
                    FriendCheckinRow(item: item) { user in
                        selectedUser = user
                    }
                    .listRowSeparator(.hidden, edges: outerSeparatorEdges(of: item))
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
                description: Text("Checkins from you and your friends will show up here.")
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
