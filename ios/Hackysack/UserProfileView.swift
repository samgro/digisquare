//
//  UserProfileView.swift
//  Hackysack
//

import SwiftUI

/// Someone's profile, pushed onto whichever navigation stack it was opened
/// from, as other social apps do, so back and further taps behave as expected.
///
/// The one profile layout in the app. Your own profile is this same view, as
/// the Profile tab and anywhere else that opens you, with Edit Profile and an
/// "Add a bio" prompt where someone else's would have friend actions.
///
/// Opened with the summary the caller already has, so the avatar and name
/// render immediately while the bio, stats and friendship load. Checkins are
/// only shown to friends; everyone sees the counts.
///
/// Push it with `.navigationDestination(item:)` bound to stored `@State`, not
/// a computed binding, which would hand it a fresh value on every body
/// evaluation.
struct UserProfileView: View {
    let user: UserSummary

    @Environment(AuthManager.self) private var authManager
    @Environment(FriendsStore.self) private var friendsStore
    @EnvironmentObject private var checkinStore: CheckinStore
    @Environment(CheckinSocialStore.self) private var socialStore

    @State private var profile: PublicProfile?
    @State private var loadError: String?
    @State private var checkins: [Checkin] = []
    @State private var hasLoadedCheckins = false
    @State private var checkinsError: String?
    @State private var actionError: String?
    @State private var isPerformingAction = false
    @State private var isConfirmingRemoval = false
    @State private var isEditing = false
    @State private var isAddingFriends = false
    @State private var selectedCheckin: CheckinDetailDestination?
    @State private var commentingCheckin: Checkin?
    /// Where the header's name ends, in the scroll content's coordinates.
    @State private var nameBottom: CGFloat = .infinity
    /// 0 while any of the header's name is on screen, even under the nav
    /// bar or status bar, rising to 1 as it scrolls off, so the nav bar's
    /// title fades in with the scroll.
    @State private var titleRevealProgress: CGFloat = 0

    private let friendsAPI = FriendsAPI()
    private let checkinsAPI = CheckinsAPI()

    /// How far past the header's name the user scrolls while the nav bar's
    /// title fades in.
    private static let titleRevealDistance: CGFloat = 16
    private static let scrollContentSpace = "scrollContent"

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: HackysackSpacing.medium) {
                    header
                    bioSection

                    if isCurrentUser {
                        HStack(spacing: HackysackSpacing.small) {
                            Button("Edit Profile") { isEditing = true }
                            Button("Add Friends") { isAddingFriends = true }
                        }
                        .buttonStyle(ProfileButtonStyle())
                    } else if let profile {
                        actionRow(for: profile)
                    }

                    if let actionError {
                        FormErrorBanner(message: actionError)
                    }
                }
                .padding(.horizontal, HackysackSpacing.medium)
                .padding(.top, HackysackSpacing.small)
                .padding(.bottom, HackysackSpacing.large)

                checkinsSection
            }
            .frame(maxWidth: .infinity)
            .coordinateSpace(.named(Self.scrollContentSpace))
        }
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            // The top of the screen, not the bottom of the nav bar: the bar is
            // transparent, so the name is still visible through it and the
            // status bar until it scrolls off the screen's top edge.
            let screenTop = geometry.visibleRect.minY
            let progress = (screenTop - nameBottom) / Self.titleRevealDistance
            return min(max(progress, 0), 1)
        } action: { _, progress in
            titleRevealProgress = progress
        }
        // Still set for the back button and its history menu; the bar shows
        // the principal item below instead.
        .navigationTitle(displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(displayName)
                    .font(.headline)
                    .lineLimit(1)
                    .opacity(titleRevealProgress)
                    .offset(y: (1 - titleRevealProgress) * 6)
                    .blur(radius: (1 - titleRevealProgress) * 2)
                    .accessibilityHidden(titleRevealProgress == 0)
            }
            .sharedBackgroundVisibility(.hidden)
        }
        .sheet(isPresented: $isEditing) {
            EditProfileView(purpose: .editing)
        }
        .navigationDestination(isPresented: $isAddingFriends) {
            AddFriendsView()
        }
        .navigationDestination(item: $selectedCheckin) { destination in
            CheckinDetailView(destination: destination)
        }
        .sheet(item: $commentingCheckin) { checkin in
            CommentsSheet(checkin: checkin)
        }
        .task(id: reloadKey) {
            await loadProfile()
        }
        .refreshable {
            await loadProfile()
        }
        // This page's checkins live in no store, so likes, comments and edits
        // made here or on a detail page are copied in as they happen. Only
        // the entries that just changed, so a reload's fresher copies stand.
        .onChange(of: socialStore.latest) { previous, latest in
            for (checkinId, changed) in latest where previous[checkinId] != changed {
                guard let index = checkins.firstIndex(where: { $0.id == checkinId }) else { continue }
                checkins[index] = changed
            }
        }
    }

    // MARK: Who this is

    /// The signed-in user's own profile, when this is them. Their header is
    /// drawn from it rather than the fetched public copy, so a save in Edit
    /// Profile shows the moment the sheet closes.
    private var currentUserProfile: UserProfile? {
        switch authManager.state {
        case .signedIn(let signedInProfile), .needsProfileSetup(let signedInProfile):
            return signedInProfile.id == user.id ? signedInProfile : nil
        case .launching, .signedOut:
            return nil
        }
    }

    private var isCurrentUser: Bool { currentUserProfile != nil }

    private var canSeeCheckins: Bool {
        isCurrentUser || profile?.friendship.status == .friends
    }

    /// Reloads after the user edits their own profile or finishes saving a
    /// checkin, so their counts and checkins don't go stale until a
    /// pull-to-refresh. Someone else's profile loads once.
    private struct ReloadKey: Equatable {
        let currentUserProfile: UserProfile?
        let savedCheckinCount: Int
    }

    private var reloadKey: ReloadKey {
        guard let currentUserProfile else {
            return ReloadKey(currentUserProfile: nil, savedCheckinCount: 0)
        }
        let savedCheckinCount = checkinStore.timelineEntries.filter { $0.syncStatus == .saved }.count
        return ReloadKey(currentUserProfile: currentUserProfile, savedCheckinCount: savedCheckinCount)
    }

    private var displayName: String {
        if let currentUserProfile {
            return PersonName.displayName(for: currentUserProfile.name)
        }
        return profile?.user.displayName ?? user.displayName
    }

    private var avatarURL: URL? {
        if let currentUserProfile {
            return currentUserProfile.avatarURL
        }
        return profile?.user.avatarURL ?? user.avatarURL
    }

    private var initials: String {
        currentUserProfile?.initials ?? profile?.user.initials ?? user.initials
    }

    private var bio: String? {
        currentUserProfile?.bio ?? profile?.user.bio
    }

    private var hometown: String? {
        currentUserProfile?.hometown ?? profile?.user.hometown
    }

    private var joinedAt: Date? {
        currentUserProfile?.createdAt ?? profile?.user.createdAt
    }

    // MARK: Header

    /// Instagram's layout: the avatar on the left and, beside it, the name,
    /// where Instagram has a username and pronouns, above the counts.
    /// The bio and subtitle go underneath, full width.
    private var header: some View {
        HStack(spacing: HackysackSpacing.large) {
            AvatarView(url: avatarURL, initials: initials, size: HackysackSize.avatarLarge)

            VStack(alignment: .leading, spacing: HackysackSpacing.small) {
                Text(displayName)
                    .font(.title2.bold())
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.frame(in: .named(Self.scrollContentSpace)).maxY
                    } action: { maxY in
                        nameBottom = maxY
                    }

                stats
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// "Truckee, CA · Joined Sep 2026" on one line where it fits, stacked
    /// where it doesn't.
    private var subtitle: some View {
        let joined = "Joined \((joinedAt ?? .now).formatted(.dateTime.month(.abbreviated).year()))"

        return ViewThatFits(in: .horizontal) {
            Text([hometown, joined].compactMap { $0 }.joined(separator: " · "))
            VStack(alignment: .leading, spacing: 0) {
                if let hometown {
                    Text(hometown)
                }
                Text(joined)
            }
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        // Placeholder bars while loading, rather than a join date that would
        // read as a real answer.
        .redacted(reason: joinedAt == nil ? .placeholder : [])
    }

    private var stats: some View {
        HStack(spacing: HackysackSpacing.large) {
            statColumn(value: profile?.checkinCount, singular: "checkin", plural: "checkins")
            statColumn(value: profile?.friendCount, singular: "friend", plural: "friends")
        }
        .accessibilityElement(children: .combine)
    }

    private func statColumn(value: Int?, singular: String, plural: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value.map { $0.formatted() } ?? "–")
                .font(.headline)
                .monospacedDigit()
                .contentTransition(.numericText())
            Text(value == 1 ? singular : plural)
                .font(.subheadline)
        }
    }

    /// The bio, or a prompt to add one on your own profile, above the
    /// hometown and join date.
    private var bioSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let bio, !bio.isEmpty {
                Text(bio)
                    .font(.subheadline)
            } else if isCurrentUser {
                Button("Add a bio", systemImage: Glyphs.add) { isEditing = true }
                    .font(.subheadline.weight(.medium))
                    .controlSize(.small)
            }

            subtitle
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Actions

    @ViewBuilder
    private func actionRow(for profile: PublicProfile) -> some View {
        switch profile.friendship.status {
        case .notFriends:
            Button("Add Friend") {
                perform { try await sendRequest() }
            }
            .buttonStyle(ProfileButtonStyle(isProminent: true))
            .disabled(isPerformingAction)

        case .outgoingRequest:
            VStack(alignment: .leading, spacing: HackysackSpacing.small) {
                Button("Cancel Request") {
                    perform { try await deleteRequest(profile.friendship.friendRequestId) }
                }
                .buttonStyle(ProfileButtonStyle())
                .disabled(isPerformingAction)

                Text("Friend request sent")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

        case .incomingRequest:
            VStack(alignment: .leading, spacing: HackysackSpacing.small) {
                Text("\(displayName) wants to be friends")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                HStack(spacing: HackysackSpacing.small) {
                    Button("Accept") {
                        perform { try await acceptRequest(profile.friendship.friendRequestId) }
                    }
                    .buttonStyle(ProfileButtonStyle(isProminent: true))

                    Button("Decline") {
                        perform { try await deleteRequest(profile.friendship.friendRequestId) }
                    }
                    .buttonStyle(ProfileButtonStyle())
                }
                .disabled(isPerformingAction)
            }

        case .friends:
            friendsButton
        }
    }

    /// Instagram's "Following" button: says you're friends, and tapping it
    /// offers to remove them.
    private var friendsButton: some View {
        Button {
            isConfirmingRemoval = true
        } label: {
            HStack(spacing: 4) {
                Text("Friends")
                Image(systemName: Glyphs.friendOptions)
                    .imageScale(.small)
            }
        }
        .buttonStyle(ProfileButtonStyle())
        .disabled(isPerformingAction)
        // Attached to the button rather than the whole view: on iOS 26 the
        // dialog presents as a popover anchored to the view it hangs off, so
        // this is what makes its arrow point at the button.
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
                    Label("Couldn't Load Profile", systemImage: Glyphs.loadError)
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
                Label("Checkins Are for Friends", systemImage: Glyphs.friendsOnly)
            } description: {
                Text("Add \(displayName) as a friend to see their checkins.")
            }
        } else if !checkins.isEmpty {
            LazyVStack(alignment: .leading, spacing: 0) {
                CheckinTimelineRows(
                    entries: checkins.map { TimelineEntry(savedCheckin: $0) },
                    onSelect: { selectedCheckin = CheckinDetailDestination(checkin: $0, author: user) },
                    onComment: { commentingCheckin = $0 }
                )
            }
            .padding(.bottom, HackysackSpacing.large)
        } else if !hasLoadedCheckins {
            ProgressView()
                .padding(.top, HackysackSpacing.large)
        } else if let checkinsError {
            ContentUnavailableView {
                Label("Couldn't Load Checkins", systemImage: Glyphs.loadError)
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
                systemImage: Glyphs.noCheckins,
                description: Text(isCurrentUser
                    ? "Tap + to check in somewhere."
                    : "\(displayName) hasn't checked in anywhere yet.")
            )
        }
    }

    // MARK: Loading

    private func loadProfile() async {
        do {
            profile = try await friendsAPI.profile(userId: user.id)
            loadError = nil
        } catch {
            // A refresh that fails keeps what is already on screen.
            if profile == nil {
                loadError = error.localizedDescription
            }
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
    NavigationStack {
        UserProfileView(user: PublicUser.preview().summary)
    }
    .environment(AuthManager())
    .environment(FriendsStore())
    .environment(LocationManager())
    .environment(CheckinSocialStore())
    .environmentObject(CheckinStore.inMemory())
}
