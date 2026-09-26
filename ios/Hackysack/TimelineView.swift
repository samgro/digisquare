//
//  TimelineView.swift
//  Hackysack
//

import SwiftData
import SwiftUI

struct TimelineView: View {
    @EnvironmentObject private var checkinStore: CheckinStore
    @Environment(CheckinHistorySync.self) private var historySync
    @Environment(AuthManager.self) private var authManager
    @Environment(SwarmImportStore.self) private var swarmImportStore
    @Query(sort: \CheckinRecord.createdAt, order: .reverse) private var records: [CheckinRecord]
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
            .homeNavigationBar(searchLabel: "Search your checkins") {
                CheckinSearchView()
            }
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
                await checkinStore.refreshTimeline()
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

    /// Pending checkins and suggestions alongside everything in the local
    /// database. A saved checkin the database couldn't take stays pending
    /// until a sync brings it down; after that the record replaces it.
    private var items: [TimelineItem] {
        var entries = checkinStore.timelineEntries
        guard !entries.isEmpty else { return records.map(TimelineItem.record) }
        if entries.contains(where: { $0.syncStatus == .saved }) {
            let recordIds = Set(records.map(\.id))
            entries.removeAll { $0.syncStatus == .saved && recordIds.contains($0.checkin.id) }
        }
        return entries.map(TimelineItem.entry) + records.map(TimelineItem.record)
    }

    @ViewBuilder
    private var content: some View {
        let visibleItems = items
        if !visibleItems.isEmpty {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    swarmImportBanner
                    CheckinTimelineRows(
                        items: visibleItems,
                        onRetry: { checkinStore.retry(entryId: $0.id) },
                        onConfirm: { checkinStore.accept(suggestionId: $0.id) },
                        onReject: { editingSuggestion = $0.suggestion },
                        onSelect: { selectedCheckin = CheckinDetailDestination(checkin: $0, author: author) },
                        onComment: { commentingCheckin = $0 }
                    )
                }
            }
            // Entries change state in place (saving → failed) without their
            // id changing, so they are compared whole; records only by id.
            .animation(.default, value: checkinStore.timelineEntries)
            .animation(.default, value: records.map(\.id))
            .animation(.default, value: swarmImportStore.bannerImport)
            .refreshable {
                await checkinStore.refreshTimeline()
                await swarmImportStore.refresh()
            }
        } else if case .failed(let failure) = historySync.status {
            // Only reached with nothing stored yet. Once there is anything to
            // show, a failed sync stays silent here; the search screen is
            // where sync problems are explained.
            ContentUnavailableView {
                Label("Couldn't Load Timeline", systemImage: Glyphs.loadError)
            } description: {
                Text(failure.message)
            } actions: {
                Button("Try Again") {
                    historySync.requestSync()
                }
            }
        } else if !historySync.hasCompletedInitialSync {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
    let historySync = CheckinHistorySync.preview(checkins: [.preview(id: "preview-coffee")])
    TimelineView()
        .environment(LocationManager())
        .environment(AuthManager())
        .environment(NotificationsStore())
        .environment(CheckinSocialStore())
        .environment(SwarmImportStore())
        .environment(historySync)
        .environmentObject(CheckinStore.inMemory())
        .modelContainer(historySync.container)
}
