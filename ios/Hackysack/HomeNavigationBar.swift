//
//  HomeNavigationBar.swift
//  Hackysack
//

import SwiftUI

/// The bar on the Timeline and Friends tabs: your avatar on the left, which
/// opens your profile; and on the right a search button and the bell, badged
/// with what is new. Each destination is pushed onto the tab's own stack.
struct HomeNavigationBar<SearchDestination: View>: ViewModifier {
    /// What the search button says to VoiceOver, e.g. "Search your checkins".
    let searchLabel: String
    /// The screen the search button pushes.
    @ViewBuilder let searchDestination: () -> SearchDestination

    @Environment(AuthManager.self) private var authManager
    @Environment(NotificationsStore.self) private var notificationsStore

    @State private var isShowingProfile = false
    @State private var isShowingNotifications = false
    @State private var isShowingSearch = false

    func body(content: Content) -> some View {
        content
            // No title shown in the bar, large or inline. It still names
            // the screen in the back button's history menu.
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(removing: .title)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        isShowingProfile = true
                    } label: {
                        // 28pt inside the standard toolbar button, which gives
                        // it the same round glass as the back button.
                        AvatarView(
                            url: authManager.currentProfile?.avatarURL,
                            initials: authManager.currentProfile?.initials ?? "?",
                            size: 28
                        )
                    }
                    .accessibilityLabel("Profile")
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isShowingSearch = true
                    } label: {
                        Label(searchLabel, systemImage: "magnifyingglass")
                    }
                }

                // Its own glass circle rather than one shared with the bell.
                ToolbarSpacer(.fixed, placement: .topBarTrailing)

                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isShowingNotifications = true
                    } label: {
                        Label("Notifications", systemImage: "bell")
                    }
                    // Zero hides the badge.
                    .badge(notificationsStore.unreadCount)
                }
            }
            .navigationDestination(isPresented: $isShowingProfile) {
                ProfileView()
            }
            .navigationDestination(isPresented: $isShowingNotifications) {
                NotificationsView()
            }
            .navigationDestination(isPresented: $isShowingSearch) {
                searchDestination()
            }
    }
}

extension View {
    func homeNavigationBar<SearchDestination: View>(
        searchLabel: String,
        @ViewBuilder searchDestination: @escaping () -> SearchDestination
    ) -> some View {
        modifier(HomeNavigationBar(searchLabel: searchLabel, searchDestination: searchDestination))
    }

    /// For a tab whose search isn't built yet: the button leads to a
    /// placeholder saying so.
    func homeNavigationBar(searchTitle: String, searchLabel: String, searchDescription: String) -> some View {
        homeNavigationBar(searchLabel: searchLabel) {
            SearchPlaceholderView(title: searchTitle, description: searchDescription)
        }
    }
}
