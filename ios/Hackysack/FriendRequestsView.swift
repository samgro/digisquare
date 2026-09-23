//
//  FriendRequestsView.swift
//  Hackysack
//

import SwiftUI

/// Full-screen list of people who want to be friends, opened from the banner
/// on Profile.
struct FriendRequestsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(FriendsStore.self) private var friendsStore

    @State private var busyRequestIds: Set<String> = []
    @State private var errorMessage: String?
    @State private var selectedUser: UserSummary?

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Friend Requests")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(role: .close) {
                            dismiss()
                        }
                    }
                }
                .safeAreaInset(edge: .top) {
                    if let errorMessage {
                        FormErrorBanner(message: errorMessage)
                            .padding(.horizontal, HackysackSpacing.medium)
                    }
                }
                .navigationDestination(item: $selectedUser) { user in
                    UserProfileView(user: user)
                }
                .task {
                    await friendsStore.loadRequests()
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        if friendsStore.incomingRequests.isEmpty {
            ContentUnavailableView(
                "No Friend Requests",
                systemImage: "person.2",
                description: Text("You're all caught up.")
            )
        } else {
            List(friendsStore.incomingRequests) { request in
                row(for: request)
            }
            .listStyle(.plain)
            .animation(.default, value: friendsStore.incomingRequests)
            .refreshable {
                await friendsStore.loadRequests()
            }
        }
    }

    private func row(for request: FriendRequest) -> some View {
        let isBusy = busyRequestIds.contains(request.id)
        return HStack(spacing: 12) {
            Button {
                selectedUser = request.user.summary
            } label: {
                HStack(spacing: 12) {
                    AvatarView(url: request.user.avatarURL, initials: request.user.initials)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(request.user.displayName)
                            .font(.headline)
                            .lineLimit(1)
                        Text("Sent \(request.createdAt.formatted(.relative(presentation: .named)))")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            // Plain, so the row's three buttons are separate tap targets.
            .buttonStyle(.plain)
            .accessibilityHint("Shows their profile")

            // Icon-only circles, as in Game Center and LinkedIn: the row
            // already says what's being asked, so the words would only crowd
            // out the name. Decline is neutral and comes first, keeping the
            // prominent Accept at the trailing edge where the thumb lands.
            HStack(spacing: 10) {
                Button {
                    respond(to: request) { try await friendsStore.deleteRequest(requestId: request.id) }
                } label: {
                    Label("Decline", systemImage: "xmark")
                }
                .buttonStyle(.bordered)
                .tint(.secondary)

                Button {
                    respond(to: request) { try await friendsStore.accept(requestId: request.id) }
                } label: {
                    Label("Accept", systemImage: "checkmark")
                }
                .buttonStyle(.borderedProminent)
            }
            .labelStyle(.iconOnly)
            .buttonBorderShape(.circle)
            .fontWeight(.semibold)
        }
        .disabled(isBusy)
        .padding(.vertical, 4)
    }

    /// The store removes the request on success, which animates the row out.
    private func respond(to request: FriendRequest, _ action: @escaping () async throws -> Void) {
        busyRequestIds.insert(request.id)
        errorMessage = nil
        Task {
            do {
                try await action()
            } catch {
                errorMessage = error.localizedDescription
            }
            busyRequestIds.remove(request.id)
        }
    }
}

/// The Profile entry point for pending requests: the requesters' faces, who
/// is asking, and the same count as the tab badge, so the badge's source is
/// obvious. Only shown while there is at least one request.
struct FriendRequestsBanner: View {
    let requests: [FriendRequest]

    private static let avatarSize: CGFloat = 32
    private static let maximumAvatars = 3

    var body: some View {
        HStack(spacing: 12) {
            avatarStack

            VStack(alignment: .leading, spacing: 2) {
                Text("Friend Requests")
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            Text(requests.count.formatted())
                .font(.subheadline.bold())
                .monospacedDigit()
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.red))

            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(requests.count) friend \(requests.count == 1 ? "request" : "requests"). \(summary)")
    }

    private var avatarStack: some View {
        HStack(spacing: -10) {
            ForEach(requests.prefix(Self.maximumAvatars)) { request in
                AvatarView(
                    url: request.user.avatarURL,
                    initials: request.user.initials,
                    size: Self.avatarSize
                )
                // A ring in the row's own background color separates the
                // overlapping faces.
                .padding(2)
                .background(Circle().fill(Color(.secondarySystemGroupedBackground)))
            }
        }
    }

    /// "Alex wants to be friends", "Alex and Sam want to be friends",
    /// "Alex and 2 others want to be friends".
    private var summary: String {
        guard let first = requests.first else { return "" }
        let firstRequesterName = first.user.displayName
        switch requests.count {
        case 1:
            return "\(firstRequesterName) wants to be friends"
        case 2:
            return "\(firstRequesterName) and \(requests[1].user.displayName) want to be friends"
        default:
            return "\(firstRequesterName) and \(requests.count - 1) others want to be friends"
        }
    }
}

#Preview("Banner") {
    List {
        Section {
            FriendRequestsBanner(requests: [
                .preview(),
                .preview(user: .preview(id: "2", name: "Sam Lee")),
                .preview(user: .preview(id: "3", name: "Jordan Kim")),
            ])
        }
        Section {
            FriendRequestsBanner(requests: [.preview()])
        }
    }
    .listStyle(.insetGrouped)
}

#Preview("Requests") {
    FriendRequestsView()
        .environment(FriendsStore())
        .environment(AuthManager())
}
