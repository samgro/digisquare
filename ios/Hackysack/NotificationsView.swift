//
//  NotificationsView.swift
//  Hackysack
//

import SwiftUI

/// The feed behind the bell: likes and comments on your checkins, and friend
/// requests you can answer in place. Opening it clears the badge.
struct NotificationsView: View {
    @Environment(NotificationsStore.self) private var notificationsStore
    @Environment(FriendsStore.self) private var friendsStore
    @Environment(AuthManager.self) private var authManager

    @State private var selectedUser: UserSummary?
    @State private var selectedCheckin: CheckinDetailDestination?
    @State private var busyNotificationIds: Set<String> = []
    @State private var errorMessage: String?

    private let checkinsAPI = CheckinsAPI()

    var body: some View {
        content
            .navigationTitle("Notifications")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .top) {
                if let errorMessage {
                    FormErrorBanner(message: errorMessage)
                        .padding(.horizontal, HackysackSpacing.medium)
                }
            }
            .navigationDestination(item: $selectedUser) { user in
                UserProfileView(user: user)
            }
            .navigationDestination(item: $selectedCheckin) { destination in
                CheckinDetailView(destination: destination)
            }
            .task {
                await notificationsStore.load()
                await notificationsStore.markAllRead()
            }
            .accentNavigationBar()
    }

    @ViewBuilder
    private var content: some View {
        if !notificationsStore.items.isEmpty {
            List(notificationsStore.items) { notification in
                NotificationRow(
                    notification: notification,
                    isBusy: busyNotificationIds.contains(notification.id),
                    onOpen: { open(notification) },
                    onSelectUser: { selectedUser = notification.actor },
                    onAccept: {
                        respond(to: notification) {
                            try await friendsStore.accept(requestId: $0)
                        }
                    },
                    onDecline: {
                        respond(to: notification) {
                            try await friendsStore.deleteRequest(requestId: $0)
                        }
                    }
                )
                .onAppear {
                    if notification.id == notificationsStore.items.last?.id {
                        Task { await notificationsStore.loadMore() }
                    }
                }
            }
            .listStyle(.plain)
            .animation(.default, value: notificationsStore.items)
            .refreshable {
                await notificationsStore.load()
                await notificationsStore.markAllRead()
            }
        } else if !notificationsStore.hasLoaded {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let loadError = notificationsStore.loadError {
            ContentUnavailableView {
                Label("Couldn't Load Notifications", systemImage: "exclamationmark.triangle")
            } description: {
                Text(loadError)
            } actions: {
                Button("Try Again") {
                    Task { await notificationsStore.load() }
                }
            }
        } else {
            ContentUnavailableView(
                "No Notifications",
                systemImage: "bell",
                description: Text("Likes, comments and friend requests will show up here.")
            )
        }
    }

    private func open(_ notification: AppNotification) {
        switch notification.kind {
        case .like, .comment:
            guard let checkinId = notification.checkin?.id else { return }
            errorMessage = nil
            Task {
                do {
                    let checkin = try await checkinsAPI.checkin(id: checkinId)
                    // Likes and comments are only ever on your own checkins.
                    let author = authManager.currentProfile?.summary
                        ?? UserSummary(id: checkin.userId, name: nil, avatarURL: nil)
                    selectedCheckin = CheckinDetailDestination(checkin: checkin, author: author)
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        case .friendRequest, .friendAccepted:
            selectedUser = notification.actor
        }
    }

    /// The server retires the request's notification when it is answered,
    /// so the row goes too.
    private func respond(
        to notification: AppNotification,
        _ action: @escaping (_ requestId: String) async throws -> Void
    ) {
        guard let requestId = notification.friendship?.id else { return }
        busyNotificationIds.insert(notification.id)
        errorMessage = nil
        Task {
            do {
                try await action(requestId)
                notificationsStore.remove(id: notification.id)
            } catch {
                errorMessage = error.localizedDescription
            }
            busyNotificationIds.remove(notification.id)
        }
    }
}

/// One line of news, with the actor's face on the left and, for a request
/// still waiting on you, Decline and Accept on the right.
struct NotificationRow: View {
    let notification: AppNotification
    let isBusy: Bool
    let onOpen: () -> Void
    let onSelectUser: () -> Void
    let onAccept: () -> Void
    let onDecline: () -> Void

    private var isPendingRequest: Bool {
        notification.kind == .friendRequest && notification.friendship?.status == .pending
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Button(action: onSelectUser) {
                AvatarView(url: notification.actor.avatarURL, initials: notification.actor.initials)
            }
            // Plain, so the row's buttons are separate tap targets.
            .buttonStyle(.plain)
            .accessibilityLabel(notification.actor.displayName)
            .accessibilityHint("Shows their profile")

            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(Text(notification.actor.displayName).fontWeight(.semibold)) \(notification.summaryText)")
                        .font(.subheadline)
                        .lineLimit(3)
                    Text(notification.createdAt.formatted(.relative(presentation: .named)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isPendingRequest {
                // Icon-only circles, as in Game Center: the row already says
                // what is being asked. Decline is neutral and comes first,
                // keeping the prominent Accept where the thumb lands.
                HStack(spacing: 10) {
                    Button(action: onDecline) {
                        Label("Decline", systemImage: "xmark")
                    }
                    .buttonStyle(.bordered)
                    .tint(.secondary)

                    Button(action: onAccept) {
                        Label("Accept", systemImage: "checkmark")
                    }
                    .buttonStyle(.borderedProminent)
                }
                .labelStyle(.iconOnly)
                .buttonBorderShape(.circle)
                .fontWeight(.semibold)
            } else if notification.isUnread {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 8, height: 8)
                    .accessibilityLabel("Unread")
            }
        }
        .disabled(isBusy)
        .padding(.vertical, 4)
    }
}

#Preview {
    NavigationStack {
        List {
            NotificationRow(notification: .preview(kind: .like), isBusy: false, onOpen: {}, onSelectUser: {}, onAccept: {}, onDecline: {})
            NotificationRow(notification: .preview(kind: .comment), isBusy: false, onOpen: {}, onSelectUser: {}, onAccept: {}, onDecline: {})
            NotificationRow(notification: .preview(kind: .friendRequest), isBusy: false, onOpen: {}, onSelectUser: {}, onAccept: {}, onDecline: {})
            NotificationRow(notification: .preview(kind: .friendAccepted, isUnread: false), isBusy: false, onOpen: {}, onSelectUser: {}, onAccept: {}, onDecline: {})
        }
        .listStyle(.plain)
        .navigationTitle("Notifications")
    }
}
