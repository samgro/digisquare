//
//  TimelineView.swift
//  Hackysack
//

import SwiftUI

struct TimelineView: View {
    @EnvironmentObject private var checkinStore: CheckinStore
    @State private var rejectingSuggestion: PendingCheckin?

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottomTrailing) {
                content
                CheckInFAB()
            }
            .navigationTitle("Timeline")
            .task {
                await checkinStore.loadTimeline()
            }
            .sheet(item: $rejectingSuggestion) { suggestion in
                RejectSuggestionSheet(
                    suggestion: suggestion,
                    onRemove: { checkinStore.remove(suggestionId: suggestion.id) },
                    onConfirm: { place in checkinStore.confirm(suggestionId: suggestion.id, place: place) }
                )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
        }
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
                        onAccept: { checkinStore.accept(suggestionId: $0.id) },
                        onReject: { rejectingSuggestion = $0.suggestion },
                        onVisibilityChange: { checkinStore.setVisibility($1, forSuggestion: $0.id) }
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
                Label("Couldn't Load Timeline", systemImage: "exclamationmark.triangle")
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
                systemImage: "mappin.and.ellipse",
                description: Text("Tap + to check in somewhere.")
            )
        }
    }
}

#Preview {
    TimelineView()
        .environment(LocationManager())
        .environmentObject(CheckinStore.inMemory())
}
