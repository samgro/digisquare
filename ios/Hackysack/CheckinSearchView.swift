//
//  CheckinSearchView.swift
//  Hackysack
//

import SwiftData
import SwiftUI

/// Free-text search across every checkin stored on the device, narrowed by
/// date, region and category chips. Pushed from the Timeline's search
/// button.
///
/// Before the user types, the screen suggests places to start: top cities,
/// categories and years.
struct CheckinSearchView: View {
    @Environment(CheckinHistorySync.self) private var historySync
    @Environment(AuthManager.self) private var authManager
    @Query(sort: \CheckinRecord.createdAt, order: .reverse) private var records: [CheckinRecord]

    @State private var searchText = ""
    /// Starts out true so the keyboard comes up with the push.
    @State private var isSearchFieldFocused = true
    @State private var filters = CheckinSearchFilters()
    @State private var presentedFilter: SearchFilterKind?
    @State private var selectedCheckin: CheckinDetailDestination?
    @State private var commentingCheckin: Checkin?

    private static let browseRowLimit = 5
    private static let suggestionLimit = 4

    var body: some View {
        // The ZStack gives the header one identity. Attached straight to
        // `content`, it would be rebuilt with each branch, recreating the
        // search field whenever the first checkins arrive.
        ZStack {
            content
        }
        .navigationTitle("Search Checkins")
        .navigationBarTitleDisplayMode(.inline)
        // A custom field rather than `.searchable`, which only activates once
        // the push has finished, so the keyboard would arrive in a second
        // step. The same as Add Friends.
        .safeAreaBar(edge: .top) {
            // The chips pad themselves vertically.
            VStack(spacing: 0) {
                SearchHeaderField(
                    text: $searchText,
                    isFocused: $isSearchFieldFocused,
                    prompt: "Places, notes, cities"
                )
                if !records.isEmpty {
                    CheckinSearchFilterBar(filters: $filters) { kind in
                        isSearchFieldFocused = false
                        presentedFilter = kind
                    }
                }
            }
            .padding(.top, 8)
        }
        .sheet(item: $presentedFilter) { kind in
            filterSheet(for: kind)
                .presentationDetents([.medium, .large])
        }
        .navigationDestination(item: $selectedCheckin) { destination in
            CheckinDetailView(destination: destination)
        }
        .sheet(item: $commentingCheckin) { checkin in
            CommentsSheet(checkin: checkin)
        }
    }

    /// Every stored checkin is the signed-in user's own.
    private var author: UserSummary {
        authManager.currentProfile?.summary ?? UserSummary(id: "", name: nil, avatarURL: nil)
    }

    private var trimmedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isSearching: Bool {
        !trimmedSearchText.isEmpty || !filters.isEmpty
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if records.isEmpty {
            emptyDatabaseState
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    CheckinSyncStatusCard()
                    if isSearching {
                        results
                    } else {
                        browse
                    }
                }
            }
            .scrollDismissesKeyboard(.immediately)
            .refreshable {
                await historySync.refresh()
            }
        }
    }

    /// Nothing stored yet, so there is nothing to search: explain why.
    @ViewBuilder
    private var emptyDatabaseState: some View {
        if case .failed(let failure) = historySync.status {
            ContentUnavailableView {
                Label(
                    "Couldn't Sync Checkins",
                    systemImage: failure.isOffline ? "wifi.slash" : "exclamationmark.icloud"
                )
            } description: {
                Text(CheckinSyncStatusCard.explanation(for: failure))
            } actions: {
                Button("Try Again") {
                    historySync.requestSync()
                }
            }
        } else if !historySync.hasCompletedInitialSync {
            ContentUnavailableView {
                Label("Syncing Your Checkins", systemImage: "arrow.triangle.2.circlepath")
            } description: {
                Text("Search will be ready in a moment.")
            } actions: {
                ProgressView()
            }
        } else {
            ContentUnavailableView(
                "No Checkins Yet",
                systemImage: "magnifyingglass",
                description: Text("Everywhere you check in will be searchable here.")
            )
        }
    }

    @ViewBuilder
    private var results: some View {
        let matches = CheckinSearch.results(in: records, text: trimmedSearchText, filters: filters)
        suggestions
        if matches.isEmpty {
            Group {
                if filters.isEmpty {
                    ContentUnavailableView.search(text: trimmedSearchText)
                } else {
                    ContentUnavailableView(
                        "No Matching Checkins",
                        systemImage: "magnifyingglass",
                        description: Text("Try a different search, or clear a filter.")
                    )
                }
            }
            .padding(.top, HackysackSpacing.extraLarge)
        } else {
            Text("^[\(matches.count) checkin](inflect: true)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.horizontal, HackysackSpacing.medium)
                .padding(.vertical, HackysackSpacing.small)
            CheckinTimelineRows(
                items: matches.map(TimelineItem.record),
                onSelect: { selectedCheckin = CheckinDetailDestination(checkin: $0, author: author) },
                onComment: { commentingCheckin = $0 }
            )
        }
    }

    // MARK: - Browse

    @ViewBuilder
    private var browse: some View {
        let cities = CheckinSearch.regionOptions(in: records)[.locality] ?? []
        let categories = CheckinSearch.categoryOptions(in: records)
        let years = CheckinSearch.years(in: records)

        if !cities.isEmpty {
            BrowseSection(title: "Top Cities") {
                ForEach(cities.prefix(Self.browseRowLimit)) { option in
                    BrowseRow(
                        title: option.region.name,
                        subtitle: option.region.subtitle,
                        checkinCount: option.checkinCount
                    ) {
                        Image(systemName: RegionLevel.locality.systemImageName)
                            .foregroundStyle(.secondary)
                            .frame(width: 36)
                    } action: {
                        filters.region = option.region
                    }
                }
            }
        }

        if !categories.isEmpty {
            BrowseSection(title: "Top Categories") {
                ForEach(categories.prefix(Self.browseRowLimit)) { option in
                    BrowseRow(title: option.name, checkinCount: option.checkinCount) {
                        PlaceIconView(primaryType: option.primaryType)
                    } action: {
                        filters.category = option.primaryType
                    }
                }
            }
        }

        if years.count > 1 {
            VStack(alignment: .leading, spacing: HackysackSpacing.small) {
                BrowseSectionHeader(title: "By Year")
                ScrollView(.horizontal) {
                    HStack(spacing: HackysackSpacing.small) {
                        ForEach(years, id: \.self) { year in
                            Button(String(year)) {
                                filters.dateRange = DateRangeFilter.year(year)
                            }
                            .font(.subheadline.weight(.medium))
                            .buttonStyle(.bordered)
                            .buttonBorderShape(.capsule)
                        }
                    }
                    .padding(.horizontal, HackysackSpacing.medium)
                }
                .scrollIndicators(.hidden)
            }
            .padding(.top, HackysackSpacing.large)
        }
    }

    // MARK: - Suggestions

    /// Areas and categories whose names match what's typed, offered as a row
    /// above the results. Picking one swaps the words for a filter chip,
    /// which is more precise than matching text. Inline rather than
    /// `.searchSuggestions`, which would cover the live results.
    @ViewBuilder
    private var suggestions: some View {
        let query = CheckinSearch.normalized(trimmedSearchText)
        let regionMatches = query.isEmpty ? [] : Array(
            CheckinSearch.regionOptions(in: records).values
                .joined()
                .filter { CheckinSearch.normalized($0.region.name).contains(query) }
                .sorted { $0.checkinCount > $1.checkinCount }
                .prefix(Self.suggestionLimit)
        )
        let categoryMatches = query.isEmpty ? [] : Array(
            CheckinSearch.categoryOptions(in: records)
                .filter { CheckinSearch.normalized($0.name).contains(query) }
                .prefix(Self.suggestionLimit)
        )

        if !regionMatches.isEmpty || !categoryMatches.isEmpty {
            ScrollView(.horizontal) {
                HStack(spacing: HackysackSpacing.small) {
                    ForEach(regionMatches) { option in
                        SuggestionChip(
                            title: option.region.name,
                            detail: [option.region.level.title, option.region.subtitle]
                                .compactMap { $0 }
                                .joined(separator: ", "),
                            systemImage: option.region.level.systemImageName
                        ) {
                            filters.region = option.region
                            searchText = ""
                        }
                    }
                    ForEach(categoryMatches) { option in
                        SuggestionChip(
                            title: option.name,
                            detail: "Category",
                            systemImage: PlaceTypeSymbol.systemImageName(for: option.primaryType)
                        ) {
                            filters.category = option.primaryType
                            searchText = ""
                        }
                    }
                }
                .padding(.horizontal, HackysackSpacing.medium)
                .padding(.top, HackysackSpacing.small)
            }
            .scrollIndicators(.hidden)
        }
    }

    // MARK: - Filter sheets

    @ViewBuilder
    private func filterSheet(for kind: SearchFilterKind) -> some View {
        switch kind {
        case .date:
            DateRangeFilterSheet(
                selection: $filters.dateRange,
                years: CheckinSearch.years(in: records)
            )
        case .region:
            RegionFilterSheet(
                selection: $filters.region,
                options: CheckinSearch.regionOptions(in: records)
            )
        case .category:
            CategoryFilterSheet(
                selection: $filters.category,
                options: CheckinSearch.categoryOptions(in: records)
            )
        }
    }
}

// MARK: - Pieces

/// "Brooklyn" with its level beneath, as a tappable capsule.
private struct SuggestionChip: View {
    let title: String
    let detail: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 0) {
                    Text(title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .lineLimit(1)
            }
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .accessibilityLabel("Filter by \(detail): \(title)")
    }
}

private struct BrowseSectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.title3.bold())
            .padding(.horizontal, HackysackSpacing.medium)
    }
}

private struct BrowseSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: HackysackSpacing.small) {
            BrowseSectionHeader(title: title)
            VStack(spacing: 0) {
                content()
            }
            .background(
                RoundedRectangle(cornerRadius: HackysackRadius.card, style: .continuous)
                    .fill(Color(.secondarySystemBackground))
            )
            .padding(.horizontal, HackysackSpacing.medium)
        }
        .padding(.top, HackysackSpacing.large)
    }
}

private struct BrowseRow<Icon: View>: View {
    let title: String
    var subtitle: String?
    let checkinCount: Int
    @ViewBuilder let icon: () -> Icon
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: HackysackSpacing.small + 4) {
                icon()
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body)
                        .foregroundStyle(.primary)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Text(checkinCount.formatted())
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, HackysackSpacing.medium)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    let historySync = CheckinHistorySync.preview(checkins: [
        .preview(id: "preview-coffee", minutesAgo: 30),
        .preview(id: "preview-park", message: "Sunday picnic", primaryType: "park", minutesAgo: 60 * 24 * 400),
    ])
    NavigationStack {
        CheckinSearchView()
    }
    .environment(historySync)
    .environment(AuthManager())
    .environment(CheckinSocialStore())
    .modelContainer(historySync.container)
}
