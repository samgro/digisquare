//
//  TimelineRows.swift
//  Hackysack
//

import SwiftUI

/// Maps Google Places primary types to glyphs and display names.
enum PlaceTypeSymbol {
    static func systemImageName(for primaryType: String?) -> String {
        guard let primaryType else { return Glyphs.placeDefault }
        switch primaryType {
        case "cafe", "coffee_shop", "bakery", "tea_house":
            return Glyphs.placeCafe
        case "bar", "pub", "wine_bar", "night_club":
            return Glyphs.placeBar
        case "park", "hiking_area", "national_park", "garden", "dog_park":
            return Glyphs.placePark
        case "gym", "fitness_center", "sports_complex":
            return Glyphs.placeGym
        case "store", "shopping_mall", "grocery_store", "supermarket", "clothing_store", "convenience_store":
            return Glyphs.placeStore
        case "movie_theater", "performing_arts_theater":
            return Glyphs.placeTheater
        case "museum", "art_gallery", "library":
            return Glyphs.placeMuseum
        case "hotel", "lodging":
            return Glyphs.placeHotel
        case "airport", "train_station", "subway_station", "bus_station", "transit_station":
            return Glyphs.placeTransit
        default:
            if primaryType.hasSuffix("restaurant") || primaryType.hasPrefix("meal_") {
                return Glyphs.placeRestaurant
            }
            return Glyphs.placeDefault
        }
    }

    /// "coffee_shop" → "Coffee Shop"
    static func displayName(for primaryType: String) -> String {
        primaryType
            .split(separator: "_")
            .map { $0.capitalized }
            .joined(separator: " ")
    }
}

struct PlaceIconView: View {
    let primaryType: String?
    /// Grays the icon out and swaps the filled disc for a dashed ring, marking
    /// a checkin that has only been suggested, not made.
    var isMuted: Bool = false

    var body: some View {
        Image(systemName: PlaceTypeSymbol.systemImageName(for: primaryType))
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(isMuted ? Color.secondary : Color.orange)
            .frame(width: 36, height: 36)
            .background {
                if isMuted {
                    Circle()
                        .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                        .foregroundStyle(.secondary)
                } else {
                    Circle().fill(Color.orange.opacity(0.15))
                }
            }
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
    // Only used by suggested entries.
    var onConfirm: () -> Void = {}
    var onReject: () -> Void = {}

    private var isSuggested: Bool { entry.syncStatus == .suggested }

    var body: some View {
        HStack(alignment: .top, spacing: TimelineMetrics.columnSpacing) {
            TimelineConnectorColumn(
                showTopLine: showTopLine,
                showBottomLine: showBottomLine,
                topLineHeight: TimelineMetrics.iconTopInset
            ) {
                PlaceIconView(primaryType: entry.checkin.placePrimaryType, isMuted: isSuggested)
            }

            VStack(alignment: .leading, spacing: 4) {
                // Top-aligned so the buttons line up with the top of the
                // place icon, which sits at the same inset as this content.
                HStack(alignment: .top, spacing: 8) {
                    CheckinDetailsRow(
                        checkin: entry.checkin,
                        showsDate: false,
                        placeNameLineLimit: isSuggested ? 1 : 2
                    )
                    // Suggested rows read as tentative until the user confirms them.
                    .opacity(isSuggested ? 0.55 : 1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if isSuggested {
                        suggestionActions
                    }
                }
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
        case .suggested, .saved:
            EmptyView()
        case .saving:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Saving…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .failed:
            Button(action: onRetry) {
                Label("Checkin failed – Retry", systemImage: Glyphs.retryCheckin)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(.red)
        }
    }

    private var suggestionActions: some View {
        HStack(spacing: 8) {
            SuggestionIconButton(
                systemImage: Glyphs.accept,
                accessibilityLabel: "Confirm Checkin",
                foreground: .white,
                background: .blue,
                action: onConfirm
            )
            SuggestionIconButton(
                systemImage: Glyphs.reject,
                accessibilityLabel: "Not Here",
                foreground: .secondary,
                background: Color(.systemGray5),
                action: onReject
            )
            .accessibilityHint("Shows other places nearby, or removes the suggestion")
        }
    }
}

/// A round, icon-only button at Apple's minimum 44×44 pt tap target.
private struct SuggestionIconButton: View {
    let systemImage: String
    let accessibilityLabel: String
    let foreground: Color
    let background: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .foregroundStyle(foreground)
                .frame(width: 44, height: 44)
                .background(background, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}

/// A day divider or a checkin, interleaved in display order so the timeline
/// can be rendered as one flat, continuously-connected list.
enum TimelineRow: Identifiable, Equatable {
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
/// ahead of each group's first entry. Suggested checkins are dated by their
/// visit's arrival, so they fall into the day the user was actually there.
func timelineRows(for entries: [TimelineEntry], calendar: Calendar = .current) -> [TimelineRow] {
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

/// A whole timeline's rows: checkins grouped under day headers, with one
/// connector line threaded through them. Put it in a LazyVStack with no
/// spacing, as the line relies on consecutive rows touching. Shared by the
/// Timeline tab and the timeline on someone's profile.
struct CheckinTimelineRows: View {
    let entries: [TimelineEntry]
    var onRetry: (TimelineEntry) -> Void = { _ in }
    // Only used by suggested entries, which only the Timeline tab has.
    var onConfirm: (TimelineEntry) -> Void = { _ in }
    var onReject: (TimelineEntry) -> Void = { _ in }

    var body: some View {
        let rows = timelineRows(for: entries)
        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
            switch row {
            case .dayHeader(let day):
                TimelineDayHeaderRow(day: day, showTopLine: index != 0)
            case .entry(let entry):
                TimelineEntryRow(
                    entry: entry,
                    showTopLine: index != 0,
                    showBottomLine: index != rows.count - 1,
                    onRetry: { onRetry(entry) },
                    onConfirm: { onConfirm(entry) },
                    onReject: { onReject(entry) }
                )
            }
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
            entry: TimelineEntry(suggestion: .preview(isOngoing: true), userId: Checkin.preview().userId)!,
            showTopLine: true,
            showBottomLine: true,
            onRetry: {}
        )
        TimelineEntryRow(
            entry: TimelineEntry(suggestion: .preview(visibility: .onlyMe), userId: Checkin.preview().userId)!,
            showTopLine: true,
            showBottomLine: true,
            onRetry: {}
        )
        TimelineEntryRow(
            entry: TimelineEntry(id: UUID(), draft: nil, checkin: .preview(), syncStatus: .saving),
            showTopLine: true,
            showBottomLine: true,
            onRetry: {}
        )
        TimelineEntryRow(
            entry: TimelineEntry(id: UUID(), draft: nil, checkin: .preview(visibility: .onlyMe), syncStatus: .saved),
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
