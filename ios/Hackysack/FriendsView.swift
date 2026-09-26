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
    @State private var selectedCheckin: CheckinDetailDestination?
    @State private var commentingCheckin: Checkin?

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottomTrailing) {
                content
                CheckInFAB()
            }
            .navigationTitle("Friends")
            .homeNavigationBar(
                searchTitle: "Search Friends",
                searchLabel: "Search friends",
                searchDescription: "Searching your friends is coming soon."
            )
            // Reached from the empty state; your profile has the everyday
            // Add Friends button.
            .navigationDestination(isPresented: $isAddingFriends) {
                AddFriendsView()
            }
            .navigationDestination(item: $selectedUser) { user in
                UserProfileView(user: user)
            }
            .navigationDestination(item: $selectedCheckin) { destination in
                CheckinDetailView(destination: destination)
            }
            .sheet(item: $commentingCheckin) { checkin in
                CommentsSheet(checkin: checkin)
            }
            .task {
                await friendsStore.loadFeed()
            }
            // Your own checkins are in the feed too, so one saved from the
            // button on this tab shows up without a pull to refresh.
            .onChange(of: checkinStore.lastSavedCheckinId) { _, _ in
                Task { await friendsStore.loadFeed() }
            }
        }
    }

    private let rowHorizontalInset: CGFloat = 16

    /// Separators only between rows, not above the first or below the last.
    private func outerSeparatorEdges(of item: FriendCheckin) -> VerticalEdge.Set {
        var edges: VerticalEdge.Set = []
        if item.id == friendsStore.feed.first?.id { edges.insert(.top) }
        if item.id == friendsStore.feed.last?.id { edges.insert(.bottom) }
        return edges
    }

    @ViewBuilder
    private var content: some View {
        if !friendsStore.feed.isEmpty {
            List {
                ForEach(friendsStore.feed) { item in
                    FriendCheckinRow(
                        item: item,
                        onSelectUser: { selectedUser = $0 },
                        onSelect: { selectedCheckin = CheckinDetailDestination(checkin: $0, author: item.user) },
                        onComment: { commentingCheckin = $0 }
                    )
                    .listRowSeparator(.hidden, edges: outerSeparatorEdges(of: item))
                    .listRowInsets(.vertical, 12)
                    .listRowInsets(.horizontal, rowHorizontalInset)
                    // From the checkin's text (the row sets that) out to
                    // the screen's edge, past the row's trailing inset.
                    .alignmentGuide(.listRowSeparatorTrailing) { dimensions in
                        dimensions.width + rowHorizontalInset
                    }
                    .onAppear {
                        if item.id == friendsStore.feed.last?.id {
                            Task { await friendsStore.loadMoreFeed() }
                        }
                    }
                }
                if friendsStore.isLoadingMoreFeed {
                    LoadingMoreRow()
                        .listRowSeparator(.hidden)
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
                Label("Couldn't Load Checkins", systemImage: Glyphs.loadError)
            } description: {
                Text(feedError)
            } actions: {
                Button("Try Again") {
                    Task { await friendsStore.loadFeed() }
                }
            }
        } else if friendsStore.friends.isEmpty {
            ContentUnavailableView {
                Label("No Friends Yet", systemImage: Glyphs.noFriends)
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
                systemImage: Glyphs.noFriends,
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
        .environment(NotificationsStore())
        .environment(CheckinSocialStore())
        .environmentObject(CheckinStore.inMemory())
}
