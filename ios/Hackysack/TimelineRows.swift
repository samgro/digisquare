//
//  TimelineRows.swift
//  Hackysack
//

import SwiftUI

/// Maps Overture place categories to glyphs and display names.
enum PlaceTypeSymbol {
    static func systemImageName(for primaryType: String?) -> String {
        guard let primaryType else { return Glyphs.placeDefault }
        switch primaryType {
        case "cafe", "coffee_shop", "bakery", "tea_room", "bubble_tea", "cafeteria", "coffee_roastery":
            return Glyphs.placeCafe
        case "bar", "pub", "wine_bar", "cocktail_bar", "beer_bar", "sports_bar", "dive_bar", "gastropub",
             "irish_pub", "brewery", "winery", "dance_club", "lounge_bar", "hotel_bar", "beach_bar", "beer_garden":
            return Glyphs.placeBar
        case "park", "hiking_trail", "national_park", "state_park", "garden", "botanical_garden", "dog_park",
             "nature_reserve", "campground", "beach", "skate_park":
            return Glyphs.placePark
        case "gym", "boxing_gym", "rock_climbing_gym", "yoga_studio", "sports_and_recreation_venue",
             "swimming_pool", "tennis_court", "sports_club_and_league", "golf_course", "ski_resort", "ski_area":
            return Glyphs.placeGym
        case "stadium_arena":
            return Glyphs.placeStadium
        case "shopping", "shopping_center", "grocery_store", "supermarket", "clothing_store", "convenience_store",
             "department_store", "bookstore", "hardware_store", "liquor_store", "pharmacy", "florist",
             "wholesale_store", "pet_store", "farmers_market":
            return Glyphs.placeStore
        case "cinema", "theatre", "theaters_and_performance_venues", "music_venue", "topic_concert_venue",
             "drive_in_theater":
            return Glyphs.placeTheater
        case "museum", "art_gallery", "library", "landmark_and_historical_building", "monument", "town_hall",
             "courthouse", "college_university", "school":
            return Glyphs.placeMuseum
        case "hotel", "resort", "bed_and_breakfast", "hostel", "motel":
            return Glyphs.placeHotel
        case "airport", "airport_terminal", "train_station", "light_rail_and_subway_stations", "bus_station",
             "public_transportation":
            return Glyphs.placeTransit
        default:
            if primaryType.hasSuffix("_museum") {
                return Glyphs.placeMuseum
            }
            if primaryType.hasSuffix("_stadium") {
                return Glyphs.placeStadium
            }
            if primaryType.hasSuffix("restaurant") || primaryType == "food_truck" || primaryType == "food_court"
                || primaryType.hasPrefix("ice_cream") {
                return Glyphs.placeRestaurant
            }
            return Glyphs.placeDefault
        }
    }

    /// "coffee_shop" → "Coffee Shop", with the curated names in
    /// `PlaceCategory` taking precedence ("light_rail_and_subway_stations" →
    /// "Subway Station").
    static func displayName(for primaryType: String) -> String {
        PlaceCategory.displayName(for: primaryType)
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
    // Only used by saved entries, the ones that exist on the server.
    var onSelect: () -> Void = {}
    var onComment: () -> Void = {}

    private var isSuggested: Bool { entry.syncStatus == .suggested }
    private var isSaved: Bool { entry.syncStatus == .saved }

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
                    details
                    if isSuggested {
                        suggestionActions
                    }
                }
                statusLine
                if isSaved {
                    CheckinActionBar(checkin: entry.checkin, onComment: onComment)
                }
            }
            .padding(.vertical, TimelineMetrics.iconTopInset)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, TimelineMetrics.horizontalPadding)
    }

    /// A saved checkin opens its detail page; the text of a placeholder or
    /// suggestion is not a button. The action bar stays outside it either
    /// way, so no button ever sits inside another.
    @ViewBuilder
    private var details: some View {
        let row = CheckinDetailsRow(
            checkin: entry.checkin,
            showsDate: false,
            placeNameLineLimit: isSuggested ? 1 : 2
        )
        // Suggested rows read as tentative until the user confirms them.
        .opacity(isSuggested ? 0.55 : 1)
        .frame(maxWidth: .infinity, alignment: .leading)

        if isSaved {
            Button(action: onSelect) {
                row.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Shows the checkin")
        } else {
            row
        }
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
                background: Color.accentColor,
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

/// One checkin on a timeline: an entry held in memory (pending, suggested,
/// or loaded for a profile), or a record from the local database.
///
/// Records are converted to a `Checkin` only when their row is built, which
/// in a lazy stack means only when it scrolls into view. A history of
/// thousands then costs one `createdAt` read per checkin to lay out, not a
/// full copy of every one on each update.
enum TimelineItem: Identifiable, Equatable {
    case entry(TimelineEntry)
    case record(CheckinRecord)

    var id: String {
        switch self {
        case .entry(let entry):
            return entry.id.uuidString
        case .record(let record):
            return record.id
        }
    }

    var createdAt: Date {
        switch self {
        case .entry(let entry):
            return entry.checkin.createdAt
        case .record(let record):
            return record.createdAt
        }
    }

    /// The day it happened on, where it happened; see `Checkin.localDay(in:)`.
    func localDay(in calendar: Calendar) -> Date {
        switch self {
        case .entry(let entry):
            return entry.checkin.localDay(in: calendar)
        case .record(let record):
            return Checkin.localDay(
                of: record.createdAt,
                timeZoneOffsetMinutes: record.timeZoneOffsetMinutes,
                in: calendar
            )
        }
    }

    var entry: TimelineEntry {
        switch self {
        case .entry(let entry):
            return entry
        case .record(let record):
            return TimelineEntry(savedCheckin: record.checkin)
        }
    }

    static func == (first: TimelineItem, second: TimelineItem) -> Bool {
        switch (first, second) {
        case let (.entry(firstEntry), .entry(secondEntry)):
            return firstEntry == secondEntry
        case let (.record(firstRecord), .record(secondRecord)):
            // Records are live objects; the row reads their changes itself.
            return firstRecord.id == secondRecord.id
        default:
            return false
        }
    }
}

/// A day divider or a checkin, interleaved in display order so the timeline
/// can be rendered as one flat, continuously-connected list.
enum TimelineRow: Identifiable, Equatable {
    case dayHeader(Date)
    case item(TimelineItem)

    var id: String {
        switch self {
        case .dayHeader(let day):
            return "day-\(day.timeIntervalSince1970)"
        case .item(let item):
            return "entry-\(item.id)"
        }
    }
}

/// Groups items by the day they happened on, where they happened, most
/// recent first, inserting a day header ahead of each group's first item.
/// Suggested checkins are dated by their visit's arrival, so they fall into
/// the day the user was actually there.
///
/// The sort is stable and close to linear on input that is already mostly in
/// order, which is how the timeline's thousands of records arrive.
func timelineRows(for items: [TimelineItem], calendar: Calendar = .current) -> [TimelineRow] {
    let sortedItems = items.sorted { $0.createdAt > $1.createdAt }
    var rows: [TimelineRow] = []
    var lastDay: Date?
    for item in sortedItems {
        let day = item.localDay(in: calendar)
        if day != lastDay {
            rows.append(.dayHeader(day))
            lastDay = day
        }
        rows.append(.item(item))
    }
    return rows
}

/// A whole timeline's rows: checkins grouped under day headers, with one
/// connector line threaded through them. Put it in a LazyVStack with no
/// spacing, as the line relies on consecutive rows touching. Shared by the
/// Timeline tab, search results and the timeline on someone's profile.
struct CheckinTimelineRows: View {
    let items: [TimelineItem]
    var onRetry: (TimelineEntry) -> Void = { _ in }
    // Only used by suggested entries, which only the Timeline tab has.
    var onConfirm: (TimelineEntry) -> Void = { _ in }
    var onReject: (TimelineEntry) -> Void = { _ in }
    // Only used by saved entries.
    var onSelect: (Checkin) -> Void = { _ in }
    var onComment: (Checkin) -> Void = { _ in }
    /// Called when the last row scrolls into view, to load the next page.
    var onReachEnd: () -> Void = {}

    var body: some View {
        let rows = timelineRows(for: items)
        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
            switch row {
            case .dayHeader(let day):
                TimelineDayHeaderRow(day: day, showTopLine: index != 0)
            case .item(let item):
                let entry = item.entry
                TimelineEntryRow(
                    entry: entry,
                    showTopLine: index != 0,
                    showBottomLine: index != rows.count - 1,
                    onRetry: { onRetry(entry) },
                    onConfirm: { onConfirm(entry) },
                    onReject: { onReject(entry) },
                    onSelect: { onSelect(entry.checkin) },
                    onComment: { onComment(entry.checkin) }
                )
                .onAppear {
                    if index == rows.count - 1 {
                        onReachEnd()
                    }
                }
            }
        }
    }
}

/// A spinner under a list while its next page loads.
struct LoadingMoreRow: View {
    var body: some View {
        ProgressView()
            .frame(maxWidth: .infinity)
            .padding(.vertical, HackysackSpacing.medium)
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
            entry: TimelineEntry(id: UUID(), draft: nil, checkin: .preview(message: nil, primaryType: "park", likeCount: 4, commentCount: 1), syncStatus: .saved),
            showTopLine: true,
            showBottomLine: false,
            onRetry: {}
        )
    }
    .environment(CheckinSocialStore())
}
