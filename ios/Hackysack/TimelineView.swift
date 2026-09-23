//
//  TimelineView.swift
//  Hackysack
//

import SwiftUI

struct TimelineView: View {
    @EnvironmentObject private var checkinStore: CheckinStore

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
        }
    }

    @ViewBuilder
    private var content: some View {
        if !checkinStore.timelineEntries.isEmpty {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    CheckinTimelineRows(entries: checkinStore.timelineEntries) { entry in
                        checkinStore.retry(entryId: entry.id)
                    }
                }
            }
            .animation(.default, value: checkinStore.timelineEntries)
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
        .environmentObject(CheckinStore())
}
