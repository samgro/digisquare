//
//  HomeNavigationBar.swift
//  Hackysack
//

import SwiftUI

/// The bar on the Timeline and Friends tabs: your avatar on the left, which
/// opens your profile, with a search button beside it; and the bell on the
/// right, badged with what is new. Each destination is pushed onto the tab's
/// own stack.
struct HomeNavigationBar: ViewModifier {
    /// The pushed search screen's title, e.g. "Search Checkins".
    let searchTitle: String
    /// What the search button says to VoiceOver, e.g. "Search your checkins".
    let searchLabel: String
    let searchDescription: String

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
                        // The size of the back button's glass circle, so the
                        // avatar stands in its place.
                        AvatarView(
                            url: authManager.currentProfile?.avatarURL,
                            initials: authManager.currentProfile?.initials ?? "?",
                            size: 44
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Profile")
                }
                // The avatar is the button, with no glass around it.
                .sharedBackgroundVisibility(.hidden)

                // Its own glass circle rather than one shared with the avatar.
                ToolbarSpacer(.fixed, placement: .topBarLeading)

                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        isShowingSearch = true
                    } label: {
                        Label(searchLabel, systemImage: "magnifyingglass")
                    }
                }

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
                SearchPlaceholderView(title: searchTitle, description: searchDescription)
            }
    }
}

extension View {
    func homeNavigationBar(searchTitle: String, searchLabel: String, searchDescription: String) -> some View {
        modifier(HomeNavigationBar(
            searchTitle: searchTitle,
            searchLabel: searchLabel,
            searchDescription: searchDescription
        ))
    }
}
