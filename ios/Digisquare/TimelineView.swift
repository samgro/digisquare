//
//  TimelineView.swift
//  Digisquare
//

import SwiftUI

/// A day divider or a checkin, interleaved in display order so the timeline
/// can be rendered as one flat, continuously-connected list.
private enum TimelineRow: Identifiable {
    case dayHeader(Date)
    case entry(TimelineEntry)

    var id: String {
        switch self {
        case .dayHeader(let day):
            return "day-\(day.timeIntervalSince1970)"
        case .entry(let entry):
            return "entry-\(entry.id)"
        }
    }
}

/// Groups entries by calendar day, most recent first, inserting a day header
/// ahead of each group's first entry.
private func timelineRows(for entries: [TimelineEntry], calendar: Calendar = .current) -> [TimelineRow] {
    let sortedEntries = entries.sorted { $0.checkin.createdAt > $1.checkin.createdAt }
    var rows: [TimelineRow] = []
    var lastDay: Date?
    for entry in sortedEntries {
        let day = calendar.startOfDay(for: entry.checkin.createdAt)
        if day != lastDay {
            rows.append(.dayHeader(day))
            lastDay = day
        }
        rows.append(.entry(entry))
    }
    return rows
}

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
                    let rows = timelineRows(for: checkinStore.timelineEntries)
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        switch row {
                        case .dayHeader(let day):
                            TimelineDayHeaderRow(day: day, showTopLine: index != 0)
                        case .entry(let entry):
                            TimelineEntryRow(
                                entry: entry,
                                showTopLine: index != 0,
                                showBottomLine: index != rows.count - 1,
                                onRetry: { checkinStore.retry(entryId: entry.id) }
                            )
                        }
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
