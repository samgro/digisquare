//
//  TimelineView.swift
//  Digisquare
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
            List(checkinStore.timelineEntries) { entry in
                TimelineCheckinRow(entry: entry) {
                    checkinStore.retry(entryId: entry.id)
                }
            }
            .listStyle(.plain)
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
                "No Check-ins Yet",
                systemImage: "mappin.and.ellipse",
                description: Text("Tap + to check in somewhere.")
            )
        }
    }
}

#Preview {
    TimelineView()
        .environmentObject(LocationManager())
        .environmentObject(CheckinStore())
}
