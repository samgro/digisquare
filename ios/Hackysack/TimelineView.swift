//
//  TimelineView.swift
//  Hackysack
//

import SwiftUI

struct TimelineView: View {
    @EnvironmentObject private var checkinStore: CheckinStore
    @Environment(AuthManager.self) private var authManager
    @Environment(SwarmImportStore.self) private var swarmImportStore
    @State private var editingSuggestion: PendingCheckin?
    @State private var selectedCheckin: CheckinDetailDestination?
    @State private var commentingCheckin: Checkin?
    @State private var isShowingSwarmImport = false

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottomTrailing) {
                content
                CheckInFAB()
            }
            .navigationTitle("Timeline")
            .homeNavigationBar(
                searchTitle: "Search Checkins",
                searchLabel: "Search your checkins",
                searchDescription: "Searching your checkins is coming soon."
            )
            .navigationDestination(item: $selectedCheckin) { destination in
                CheckinDetailView(destination: destination)
            }
            .navigationDestination(isPresented: $isShowingSwarmImport) {
                SwarmImportView()
            }
            .sheet(item: $commentingCheckin) { checkin in
                CommentsSheet(checkin: checkin)
            }
            .task {
                await checkinStore.loadTimeline()
            }
            .sheet(item: $editingSuggestion) { suggestion in
                EditSuggestionSheet(
                    suggestion: suggestion,
                    onRemove: { checkinStore.remove(suggestionId: suggestion.id) },
                    onConfirm: { place, visibility in
                        checkinStore.confirm(suggestionId: suggestion.id, place: place, visibility: visibility)
                    }
                )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
        }
    }

    /// Every row here is the signed-in user's own checkin.
    private var author: UserSummary {
        authManager.currentProfile?.summary
            ?? UserSummary(id: checkinStore.currentUserId ?? "", name: nil, avatarURL: nil)
    }

    @ViewBuilder
    private var content: some View {
        let timelineEntries = checkinStore.timelineEntries
        if !timelineEntries.isEmpty {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    swarmImportBanner
                    CheckinTimelineRows(
                        entries: timelineEntries,
                        onRetry: { checkinStore.retry(entryId: $0.id) },
                        onConfirm: { checkinStore.accept(suggestionId: $0.id) },
                        onReject: { editingSuggestion = $0.suggestion },
                        onSelect: { selectedCheckin = CheckinDetailDestination(checkin: $0, author: author) },
                        onComment: { commentingCheckin = $0 },
                        onReachEnd: { Task { await checkinStore.loadMoreTimeline() } }
                    )
                    if checkinStore.isLoadingMoreTimeline {
                        LoadingMoreRow()
                    }
                }
            }
            .animation(.default, value: timelineEntries)
            .animation(.default, value: swarmImportStore.bannerImport)
            .refreshable {
                await checkinStore.loadTimeline()
                await swarmImportStore.refresh()
            }
        } else if !checkinStore.hasLoadedTimeline {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let timelineError = checkinStore.timelineError {
            ContentUnavailableView {
                Label("Couldn't Load Timeline", systemImage: Glyphs.loadError)
            } description: {
                Text(timelineError)
            } actions: {
                Button("Try Again") {
                    Task { await checkinStore.loadTimeline() }
                }
            }
        } else {
            VStack(spacing: 0) {
                swarmImportBanner
                emptyState
            }
            .animation(.default, value: swarmImportStore.bannerImport)
        }
    }

    /// Sits above the rows while Swarm history comes in, and for a moment
    /// after, so a fresh account watches its timeline fill up.
    @ViewBuilder
    private var swarmImportBanner: some View {
        if let bannerImport = swarmImportStore.bannerImport {
            SwarmImportBanner(swarmImport: bannerImport) {
                isShowingSwarmImport = true
            }
        }
    }

    /// A new account's first sight of the timeline. Most people arriving
    /// here have years of Swarm history, so bringing it over is the first
    /// thing offered; checking in by hand is the other way to start. Shown
    /// whenever there are no checkins, whatever the import store knows: while
    /// an import runs, the banner above it says so.
    private var emptyState: some View {
        ContentUnavailableView {
            Label {
                Text("Import your Swarm checkins")
            } icon: {
                Text("🐝")
                    .font(.system(size: 56))
                    .accessibilityHidden(true)
            }
        } description: {
            Text("Bring your whole history over, photos and all. Or tap + to check in somewhere new.")
        } actions: {
            Button("Import from Swarm") {
                isShowingSwarmImport = true
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

#Preview {
    TimelineView()
        .environment(LocationManager())
        .environment(AuthManager())
        .environment(NotificationsStore())
        .environment(CheckinSocialStore())
        .environment(SwarmImportStore())
        .environmentObject(CheckinStore.inMemory())
}
