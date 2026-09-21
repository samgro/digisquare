//
//  TimelineRows.swift
//  Digisquare
//

import SwiftUI

struct PlaceIconView: View {
    let primaryType: String?

    var body: some View {
        Image(systemName: PlaceTypeSymbol.systemImageName(for: primaryType))
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(Color.orange)
            .frame(width: 36, height: 36)
            .background(Circle().fill(Color.orange.opacity(0.15)))
    }
}

/// Shared by the day header and entry rows so their markers sit on one
/// vertical axis. Every row spans the full width and pads its own content
/// rather than itself, which is what keeps the connector line unbroken.
private enum TimelineMetrics {
    static let columnWidth: CGFloat = 36
    static let columnSpacing: CGFloat = 12
    static let horizontalPadding: CGFloat = 16
    /// Distance from the top of an entry row to the top of its icon, matching
    /// the content's top padding so the icon lines up with the place name.
    static let iconTopInset: CGFloat = 12
    /// Where a row's text begins, clearing the connector column. Day headers
    /// inset their own text by this much so they line up with place names.
    static var textLeadingInset: CGFloat { horizontalPadding + columnWidth + columnSpacing }
}

/// Draws the vertical line that threads through every marker in the
/// timeline, Swarm-style — each row only knows whether its own top and
/// bottom segments should be visible, so the line reads as continuous once
/// consecutive rows are stacked with no spacing between them.
private struct TimelineConnectorColumn<Marker: View>: View {
    let showTopLine: Bool
    let showBottomLine: Bool
    /// Height of the segment above the marker. `nil` lets it flex, which
    /// centers the marker in the row; a value pins the marker that far down.
    var topLineHeight: CGFloat?
    @ViewBuilder let marker: () -> Marker

    var body: some View {
        VStack(spacing: 0) {
            line(visible: showTopLine)
                .frame(height: topLineHeight)
            marker()
            line(visible: showBottomLine)
        }
        .frame(width: TimelineMetrics.columnWidth)
    }

    private func line(visible: Bool) -> some View {
        Rectangle()
            .fill(visible ? Color.orange.opacity(0.4) : Color.clear)
            .frame(width: 2)
            .frame(maxHeight: .infinity)
    }
}

/// A date divider between days of checkins, e.g. "Today" or "Yesterday".
struct TimelineDayHeaderRow: View {
    let day: Date
    let showTopLine: Bool

    var body: some View {
        HStack(spacing: 0) {
            // The leading padding both aligns the label with the place names
            // below and stretches the band it sits on out to the screen edge.
            Text(RelativeDay.label(for: day))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, TimelineMetrics.textLeadingInset)
                .padding(.trailing, 16)
                .padding(.vertical, 6)
                .background(
                    UnevenRoundedRectangle(bottomTrailingRadius: 16, topTrailingRadius: 16)
                        .fill(Color(.secondarySystemBackground))
                )
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
        .overlay(alignment: .leading) {
            TimelineConnectorColumn(showTopLine: showTopLine, showBottomLine: true) {
                Circle()
                    .fill(Color.orange)
                    .frame(width: 8, height: 8)
            }
            .padding(.leading, TimelineMetrics.horizontalPadding)
        }
    }
}

struct TimelineEntryRow: View {
    let entry: TimelineEntry
    let showTopLine: Bool
    let showBottomLine: Bool
    let onRetry: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: TimelineMetrics.columnSpacing) {
            TimelineConnectorColumn(
                showTopLine: showTopLine,
                showBottomLine: showBottomLine,
                topLineHeight: TimelineMetrics.iconTopInset
            ) {
                PlaceIconView(primaryType: entry.checkin.placePrimaryType)
            }

            VStack(alignment: .leading, spacing: 4) {
                CheckinDetailsRow(checkin: entry.checkin)
                statusLine
            }
            .padding(.vertical, TimelineMetrics.iconTopInset)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, TimelineMetrics.horizontalPadding)
    }

    @ViewBuilder
    private var statusLine: some View {
        switch entry.syncStatus {
        case .saving:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Saving…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .saved:
            EmptyView()
        case .failed:
            Button(action: onRetry) {
                Label("Check-in failed – Retry", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(.red)
        }
    }
}

#Preview("Day Header") {
    TimelineDayHeaderRow(day: Date(), showTopLine: false)
}

#Preview("States") {
    VStack(spacing: 0) {
        TimelineDayHeaderRow(day: Date(), showTopLine: false)
        TimelineEntryRow(
            entry: TimelineEntry(id: UUID(), draft: nil, checkin: .preview(), syncStatus: .saving),
            showTopLine: true,
            showBottomLine: true,
            onRetry: {}
        )
        TimelineEntryRow(
            entry: TimelineEntry(id: UUID(), draft: nil, checkin: .preview(), syncStatus: .saved),
            showTopLine: true,
            showBottomLine: true,
            onRetry: {}
        )
        TimelineEntryRow(
            entry: TimelineEntry(id: UUID(), draft: nil, checkin: .preview(), syncStatus: .failed),
            showTopLine: true,
            showBottomLine: true,
            onRetry: {}
        )
        TimelineEntryRow(
            entry: TimelineEntry(id: UUID(), draft: nil, checkin: .preview(message: nil, primaryType: "park"), syncStatus: .saved),
            showTopLine: true,
            showBottomLine: false,
            onRetry: {}
        )
    }
}
