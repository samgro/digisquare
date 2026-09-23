//
//  ProfileView.swift
//  Hackysack
//

import SwiftUI

/// Your own profile, laid out the way friends will see you: photo, name,
/// hometown and bio up top, then your numbers and the places you go most.
/// Account details and sign out live a level down, in Settings.
struct ProfileView: View {
    @Environment(AuthManager.self) private var authManager
    @Environment(FriendsStore.self) private var friendsStore
    @EnvironmentObject private var checkinStore: CheckinStore

    @State private var isEditing = false
    @State private var isShowingFriendRequests = false
    @State private var didFailToRefresh = false
    @State private var stats: ProfileStats?

    private var profile: UserProfile? {
        switch authManager.state {
        case .signedIn(let profile), .needsProfileSetup(let profile):
            return profile
        case .launching, .signedOut:
            return nil
        }
    }

    /// Changes whenever a checkin finishes saving, so the stats reload after
    /// the user checks in somewhere instead of going stale until a
    /// pull-to-refresh.
    private var statsReloadKey: String {
        let savedCount = checkinStore.timelineEntries.filter { $0.syncStatus == .saved }.count
        return "\(profile?.id ?? "")-\(savedCount)"
    }

    var body: some View {
        NavigationStack {
            Group {
                if let profile {
                    profileContent(profile)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        SettingsView()
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                }
            }
            .sheet(isPresented: $isEditing) {
                EditProfileView(purpose: .editing)
            }
            .task(id: statsReloadKey) {
                await loadStats()
            }
            .fullScreenCover(isPresented: $isShowingFriendRequests) {
                FriendRequestsView()
            }
        }
    }

    private func profileContent(_ profile: UserProfile) -> some View {
        ScrollView {
            VStack(spacing: HackysackSpacing.large) {
                header(profile)

                // Directly under the header, where it's the first thing seen
                // after tapping the badged tab, and gone entirely when there
                // is nothing to review.
                if !friendsStore.incomingRequests.isEmpty {
                    Button {
                        isShowingFriendRequests = true
                    } label: {
                        FriendRequestsBanner(requests: friendsStore.incomingRequests)
                            .padding(.horizontal, HackysackSpacing.medium)
                            .padding(.vertical, 12)
                            .background(cardBackground)
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    isEditing = true
                } label: {
                    Text("Edit Profile")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                .controlSize(.large)

                statsCard

                topPlacesSection
            }
            .padding(.horizontal, HackysackSpacing.medium)
            .padding(.bottom, HackysackSpacing.extraLarge)
        }
        .animation(.default, value: friendsStore.incomingRequests.isEmpty)
        .background(alignment: .top) {
            // A soft wash of the accent color that runs up under the glass
            // navigation bar, so the header reads as a cover rather than a
            // form.
            LinearGradient(
                colors: [Color.accentColor.opacity(0.28), Color.accentColor.opacity(0)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 360)
            .ignoresSafeArea()
        }
        .background(Color(.systemGroupedBackground))
        .refreshable {
            await friendsStore.loadRequests()
            await authManager.refreshProfile()
            didFailToRefresh = authManager.lastError != nil
            await loadStats()
        }
    }

    // MARK: - Header

    private func header(_ profile: UserProfile) -> some View {
        VStack(spacing: HackysackSpacing.medium) {
            AvatarView(
                url: profile.avatarURL,
                initials: profile.initials,
                size: HackysackSize.avatarHero
            )
            .overlay(Circle().strokeBorder(Color(.systemBackground), lineWidth: 4))
            .shadow(color: .black.opacity(0.12), radius: 16, y: 8)

            VStack(spacing: HackysackSpacing.small / 2) {
                Text(profile.name ?? "\(AppInfo.name) member")
                    .font(.title.bold())
                    .multilineTextAlignment(.center)

                metadataLine(profile)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if let bio = profile.bio, !bio.isEmpty {
                Text(bio)
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, HackysackSpacing.medium)
            } else {
                Button("Add a bio", systemImage: "plus") { isEditing = true }
                    .font(.subheadline.weight(.medium))
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
            }

            if didFailToRefresh {
                // The cached profile is still on screen and still correct.
                // Replacing it with an error state would be a downgrade, so
                // this is only a quiet note.
                Text("Couldn't refresh")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, HackysackSpacing.medium)
    }

    /// "📍 Truckee, CA · Joined September 2026" on one line where it fits,
    /// stacked where it doesn't.
    private func metadataLine(_ profile: UserProfile) -> some View {
        let joined = Label(
            "Joined \(profile.createdAt.formatted(.dateTime.month(.wide).year()))",
            systemImage: "calendar"
        )

        return ViewThatFits(in: .horizontal) {
            HStack(spacing: HackysackSpacing.small) {
                if let hometown = profile.hometown {
                    Label(hometown, systemImage: "mappin.and.ellipse")
                    Text("·")
                }
                joined
            }
            VStack(spacing: HackysackSpacing.small / 2) {
                if let hometown = profile.hometown {
                    Label(hometown, systemImage: "mappin.and.ellipse")
                }
                joined
            }
        }
        .labelStyle(CompactLabelStyle())
        .lineLimit(1)
    }

    // MARK: - Stats

    private var statsCard: some View {
        HStack(spacing: 0) {
            statColumn(value: stats?.checkinCount, singular: "Checkin", plural: "Checkins")
            Divider()
                .frame(height: 36)
            statColumn(value: stats?.placeCount, singular: "Place", plural: "Places")
        }
        .padding(.vertical, HackysackSpacing.medium)
        .background(cardBackground)
        .animation(.default, value: stats)
    }

    private func statColumn(value: Int?, singular: String, plural: String) -> some View {
        VStack(spacing: 2) {
            Text(value.map { $0.formatted() } ?? "–")
                .font(.title2.bold())
                .monospacedDigit()
                .contentTransition(.numericText())
            Text(value == 1 ? singular : plural)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Top places

    @ViewBuilder
    private var topPlacesSection: some View {
        if let stats {
            VStack(alignment: .leading, spacing: HackysackSpacing.small) {
                Text("Top Places")
                    .font(.title3.bold())
                    .padding(.horizontal, HackysackSpacing.small / 2)

                VStack(spacing: 0) {
                    if stats.topPlaces.isEmpty {
                        Text("Places you check in most will show up here.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(HackysackSpacing.medium)
                    } else {
                        ForEach(Array(stats.topPlaces.enumerated()), id: \.element.id) { index, place in
                            topPlaceRow(place)
                            if index < stats.topPlaces.count - 1 {
                                Divider()
                                    .padding(.leading, HackysackSpacing.medium + 36 + 12)
                            }
                        }
                    }
                }
                .background(cardBackground)
            }
        }
    }

    private func topPlaceRow(_ place: ProfileStats.TopPlace) -> some View {
        HStack(spacing: 12) {
            PlaceIconView(primaryType: place.placePrimaryType)
            VStack(alignment: .leading, spacing: 2) {
                Text(place.placeName)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text(place.checkinCount == 1 ? "1 checkin" : "\(place.checkinCount) checkins")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, HackysackSpacing.medium)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: HackysackRadius.card, style: .continuous)
            .fill(Color(.secondarySystemGroupedBackground))
    }

    // MARK: - Loading

    /// A failure keeps whatever was last shown: stale numbers beat a blank
    /// card, and the next checkin or pull-to-refresh tries again.
    private func loadStats() async {
        guard let profileId = profile?.id else { return }
        if let loaded = try? await ProfileStats.load(userId: profileId) {
            stats = loaded
        }
    }
}

/// Icon and title close together, for a line of small metadata.
private struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon
                .imageScale(.small)
            configuration.title
        }
    }
}

#Preview {
    ProfileView()
        .environment(AuthManager())
        .environment(FriendsStore())
        .environmentObject(CheckinStore.inMemory())
}
