//
//  HomeNavigationBar.swift
//  Hackysack
//

import SwiftUI

/// The bar on the Timeline and Friends tabs: your avatar on the left, which
/// opens your profile; a search bar in the middle; and the bell on the
/// right, badged with what is new. Each destination is pushed onto the tab's
/// own stack.
struct HomeNavigationBar: ViewModifier {
    /// The pushed search screen's title, e.g. "Search Checkins".
    let searchTitle: String
    /// The prompt in the bar, e.g. "Search your checkins".
    let searchPrompt: String
    let searchDescription: String

    @Environment(AuthManager.self) private var authManager
    @Environment(NotificationsStore.self) private var notificationsStore

    @State private var isShowingProfile = false
    @State private var isShowingNotifications = false
    @State private var isShowingSearch = false

    func body(content: Content) -> some View {
        content
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

                ToolbarItem(placement: .principal) {
                    SearchBarButton(prompt: searchPrompt) {
                        isShowingSearch = true
                    }
                }
                // The capsule draws its own glass; the toolbar's would double it.
                .sharedBackgroundVisibility(.hidden)

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
            .accentNavigationBar()
    }
}

/// Looks like a search field, acts like a button: the real field lives on
/// the screen it pushes, where it can come up with the keyboard.
private struct SearchBarButton: View {
    let prompt: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                Text(prompt)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(.subheadline)
            .padding(.horizontal, 12)
            .frame(height: 36)
            .frame(maxWidth: .infinity)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
        .accessibilityLabel(prompt)
    }
}

extension View {
    func homeNavigationBar(searchTitle: String, searchPrompt: String, searchDescription: String) -> some View {
        modifier(HomeNavigationBar(
            searchTitle: searchTitle,
            searchPrompt: searchPrompt,
            searchDescription: searchDescription
        ))
    }
}
