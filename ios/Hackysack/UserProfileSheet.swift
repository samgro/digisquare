//
//  UserProfileSheet.swift
//  Hackysack
//

import SwiftUI

/// Someone else's profile, as a half sheet that drags up to full height.
///
/// Opened with the summary the caller already has, so the avatar and name
/// render immediately while the bio, stats and friendship load. Their
/// checkins are only shown to friends; everyone sees the count.
///
/// Present it with `.sheet(item:)` bound to stored `@State`, not a computed
/// binding: a fresh value on every body evaluation re-presents the sheet in a
/// loop (see EditProfileView).
struct UserProfileSheet: View {
    let user: UserSummary

    @Environment(AuthManager.self) private var authManager
    @Environment(FriendsStore.self) private var friendsStore

    @State private var profile: PublicProfile?
    @State private var loadError: String?
    @State private var checkins: [Checkin] = []
    @State private var hasLoadedCheckins = false
    @State private var checkinsError: String?
    @State private var actionError: String?
    @State private var isPerformingAction = false
    @State private var isConfirmingRemoval = false

    private let friendsAPI = FriendsAPI()
    private let checkinsAPI = CheckinsAPI()

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                header
                    .padding(.horizontal, HackysackSpacing.large)
                    .padding(.top, HackysackSpacing.extraLarge)
                    .padding(.bottom, HackysackSpacing.large)

                checkinsSection
            }
            .frame(maxWidth: .infinity)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .task {
            await loadProfile()
        }
    }

    // MARK: Header

    private var displayName: String { profile?.user.displayName ?? user.displayName }

    private var isCurrentUser: Bool {
        switch authManager.state {
        case .signedIn(let signedInProfile), .needsProfileSetup(let signedInProfile):
            return signedInProfile.id == user.id
        case .launching, .signedOut:
            return false
        }
    }

    private var canSeeCheckins: Bool {
        isCurrentUser || profile?.friendship.status == .friends
    }

    private var header: some View {
        VStack(spacing: HackysackSpacing.medium) {
            AvatarView(
                url: profile?.user.avatarURL ?? user.avatarURL,
                initials: profile?.user.initials ?? user.initials,
                size: HackysackSize.avatarLarge
            )

            VStack(spacing: 4) {
                Text(displayName)
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)

                Text("Joined \(AppInfo.name) \(joinedDate)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .redacted(reason: profile == nil ? .placeholder : [])

                if let bio = profile?.user.bio, !bio.isEmpty {
                    Text(bio)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }

            statsRow

            if let profile, !isCurrentUser {
                actionRow(for: profile)
            }

            if let actionError {
                FormErrorBanner(message: actionError)
            }
        }
    }

    private var joinedDate: String {
        (profile?.user.createdAt ?? .now).formatted(.dateTime.month(.wide).year())
    }

    private var statsRow: some View {
        HStack(spacing: 0) {
            statColumn(
                value: profile.map { $0.checkinCount.formatted() } ?? "0",
                label: profile?.checkinCount == 1 ? "Checkin" : "Checkins"
            )

            Divider()
                .frame(height: 32)

            statColumn(
                value: profile.map { $0.friendCount.formatted() } ?? "0",
                label: profile?.friendCount == 1 ? "Friend" : "Friends"
            )
        }
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: HackysackRadius.card, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
        // Placeholder bars while loading, rather than a "0 Checkins" that
        // would read as a real answer.
        .redacted(reason: profile == nil ? .placeholder : [])
        .accessibilityElement(children: .combine)
    }

    private func statColumn(value: String, label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.headline)
                .monospacedDigit()
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Actions

    @ViewBuilder
    private func actionRow(for profile: PublicProfile) -> some View {
        switch profile.friendship.status {
        case .notFriends:
            Button {
                perform { try await sendRequest() }
            } label: {
                Label("Add Friend", systemImage: "person.badge.plus")
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(isPerformingAction)

        case .outgoingRequest:
            VStack(spacing: HackysackSpacing.small) {
                Button {
                    perform { try await deleteRequest(profile.friendship.friendRequestId) }
                } label: {
                    Label("Cancel Request", systemImage: "xmark")
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(isPerformingAction)

                Text("Friend request sent")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

        case .incomingRequest:
            VStack(spacing: HackysackSpacing.small) {
                Text("\(displayName) wants to be friends")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                HStack(spacing: HackysackSpacing.small) {
                    Button("Accept") {
                        perform { try await acceptRequest(profile.friendship.friendRequestId) }
                    }
                    .buttonStyle(PrimaryButtonStyle())

                    Button("Decline") {
                        perform { try await deleteRequest(profile.friendship.friendRequestId) }
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
                .disabled(isPerformingAction)
            }

        case .friends:
            HStack(spacing: HackysackSpacing.medium) {
                Label("Friends", systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)

                Button("Remove Friend", role: .destructive) {
                    isConfirmingRemoval = true
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.red)
                .disabled(isPerformingAction)
                // Attached to the button rather than the sheet: on iOS 26 the
                // dialog presents as a popover anchored to the view it hangs
                // off, so this is what makes its arrow point at the button.
                .confirmationDialog(
                    "Remove \(displayName) as a friend?",
                    isPresented: $isConfirmingRemoval,
                    titleVisibility: .visible
                ) {
                    Button("Remove Friend", role: .destructive) {
                        perform { try await removeFriend() }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("They won't be notified, and you'll stop seeing each other's checkins.")
                }
            }
        }
    }

    /// Runs one friendship action at a time, surfacing its error under the
    /// buttons rather than replacing the profile with an error state.
    private func perform(_ action: @escaping () async throws -> Void) {
        guard !isPerformingAction else { return }
        isPerformingAction = true
        actionError = nil
        Task {
            do {
                try await action()
            } catch {
                actionError = error.localizedDescription
            }
            isPerformingAction = false
        }
    }

    private func sendRequest() async throws {
        let friendship = try await friendsStore.sendRequest(to: user.id)
        await applyFriendship(friendship)
    }

    private func acceptRequest(_ requestId: String?) async throws {
        guard let requestId else { return }
        try await friendsStore.accept(requestId: requestId)
        await applyFriendship(.friends)
    }

    private func deleteRequest(_ requestId: String?) async throws {
        guard let requestId else { return }
        try await friendsStore.deleteRequest(requestId: requestId)
        await applyFriendship(.notFriends)
    }

    private func removeFriend() async throws {
        try await friendsStore.removeFriend(userId: user.id)
        await applyFriendship(.notFriends)
    }

    private func applyFriendship(_ friendship: FriendshipState) async {
        withAnimation {
            profile?.friendship = friendship
        }
        if canSeeCheckins {
            await loadCheckins()
        } else {
            checkins = []
            hasLoadedCheckins = false
        }
    }

    // MARK: Checkins

    @ViewBuilder
    private var checkinsSection: some View {
        if profile == nil {
            if let loadError {
                ContentUnavailableView {
                    Label("Couldn't Load Profile", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(loadError)
                } actions: {
                    Button("Try Again") {
                        Task { await loadProfile() }
                    }
                }
            } else {
                ProgressView()
                    .padding(.top, HackysackSpacing.large)
            }
        } else if !canSeeCheckins {
            ContentUnavailableView {
                Label("Checkins Are for Friends", systemImage: "lock.fill")
            } description: {
                Text("Add \(displayName) as a friend to see their checkins.")
            }
        } else if !checkins.isEmpty {
            LazyVStack(alignment: .leading, spacing: 0) {
                CheckinTimelineRows(entries: checkins.map { TimelineEntry(savedCheckin: $0) })
            }
            .padding(.bottom, HackysackSpacing.large)
        } else if !hasLoadedCheckins {
            ProgressView()
                .padding(.top, HackysackSpacing.large)
        } else if let checkinsError {
            ContentUnavailableView {
                Label("Couldn't Load Checkins", systemImage: "exclamationmark.triangle")
            } description: {
                Text(checkinsError)
            } actions: {
                Button("Try Again") {
                    Task { await loadCheckins() }
                }
            }
        } else {
            ContentUnavailableView(
                "No Checkins Yet",
                systemImage: "mappin.and.ellipse",
                description: Text("\(displayName) hasn't checked in anywhere yet.")
            )
        }
    }

    // MARK: Loading

    private func loadProfile() async {
        do {
            profile = try await friendsAPI.profile(userId: user.id)
            loadError = nil
        } catch {
            loadError = error.localizedDescription
            return
        }
        if canSeeCheckins {
            await loadCheckins()
        }
    }

    private func loadCheckins() async {
        do {
            // The API's maximum page. There is no paging yet, so someone
            // with more than this shows their most recent 100 under a count
            // that is higher.
            checkins = try await checkinsAPI.listCheckins(userId: user.id, limit: 100)
            checkinsError = nil
        } catch {
            checkinsError = error.localizedDescription
        }
        hasLoadedCheckins = true
    }
}

#Preview {
    Text("Timeline")
        .sheet(isPresented: .constant(true)) {
            UserProfileSheet(user: PublicUser.preview().summary)
        }
        .environment(AuthManager())
        .environment(FriendsStore())
}
