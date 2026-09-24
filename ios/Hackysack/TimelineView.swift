//
//  TimelineView.swift
//  Hackysack
//

import SwiftUI

struct TimelineView: View {
    @EnvironmentObject private var checkinStore: CheckinStore
    @Environment(AuthManager.self) private var authManager
    @State private var editingSuggestion: PendingCheckin?
    @State private var selectedCheckin: CheckinDetailDestination?
    @State private var commentingCheckin: Checkin?

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottomTrailing) {
                content
                CheckInFAB()
            }
            .navigationTitle("Timeline")
            .homeNavigationBar(
                searchTitle: "Search Checkins",
                searchPrompt: "Search your checkins",
                searchDescription: "Searching your checkins is coming soon."
            )
            #if DEBUG
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    DebugVisitMenu()
                }
            }
            #endif
            .navigationDestination(item: $selectedCheckin) { destination in
                CheckinDetailView(destination: destination)
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
                    CheckinTimelineRows(
                        entries: timelineEntries,
                        onRetry: { checkinStore.retry(entryId: $0.id) },
                        onConfirm: { checkinStore.accept(suggestionId: $0.id) },
                        onReject: { editingSuggestion = $0.suggestion },
                        onSelect: { selectedCheckin = CheckinDetailDestination(checkin: $0, author: author) },
                        onComment: { commentingCheckin = $0 }
                    )
                }
            }
            .animation(.default, value: timelineEntries)
            .refreshable {
                await checkinStore.loadTimeline()
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
            ContentUnavailableView(
                "No Checkins Yet",
                systemImage: Glyphs.noCheckins,
                description: Text("Tap + to check in somewhere.")
            )
        }
    }
}

#Preview {
    TimelineView()
        .environment(LocationManager())
        .environment(AuthManager())
        .environment(NotificationsStore())
        .environment(CheckinSocialStore())
        .environmentObject(CheckinStore.inMemory())
}
