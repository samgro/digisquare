//
//  CheckinSearch.swift
//  Hackysack
//

import Foundation

/// The administrative levels search can filter by, broadest last.
enum RegionLevel: String, CaseIterable, Identifiable, Hashable {
    case locality
    case administrativeArea
    case country

    var id: String { rawValue }

    /// Section headers in the region picker.
    var pluralTitle: String {
        switch self {
        case .locality: return "Cities"
        case .administrativeArea: return "States & Provinces"
        case .country: return "Countries"
        }
    }

    var title: String {
        switch self {
        case .locality: return "City"
        case .administrativeArea: return "State or Province"
        case .country: return "Country"
        }
    }

    var systemImageName: String {
        switch self {
        case .locality: return "building.2"
        case .administrativeArea: return "map"
        case .country: return "globe"
        }
    }
}

/// Display names for the codes checkins store their region and country as.
nonisolated enum RegionName {
    /// "US-CA" → "CA", the way it's written in an address. The few regions
    /// carried over from Google as plain names are shown as they are.
    static func administrativeArea(_ region: String) -> String {
        let parts = region.split(separator: "-", maxSplits: 1)
        guard parts.count == 2, parts[0].count == 2, parts[0].allSatisfy(\.isUppercase) else {
            return region
        }
        return String(parts[1])
    }

    /// "US" → "United States", in the user's language. Anything Locale
    /// doesn't know as a region code is shown as it is.
    static func country(_ code: String) -> String {
        Locale.current.localizedString(forRegionCode: code) ?? code
    }
}

/// One specific area, e.g. the city of Portland in Oregon.
///
/// The area above it and the country are part of its identity, so the two
/// Portlands (Oregon and Maine) stay separate.
struct RegionFilter: Hashable, Identifiable {
    let level: RegionLevel
    /// What records store at this level: a city's name, "US-CA" or "US".
    let value: String
    /// The stored value one level up: the region for a city.
    let parentValue: String?
    let countryCode: String?

    var id: String {
        [level.rawValue, value, parentValue ?? "", countryCode ?? ""].joined(separator: "|")
    }

    /// "Portland", "OR" or "United States".
    var name: String {
        switch level {
        case .locality: return value
        case .administrativeArea: return RegionName.administrativeArea(value)
        case .country: return RegionName.country(value)
        }
    }

    /// "OR · United States", for telling same-named areas apart.
    var subtitle: String? {
        let parts = [
            parentValue.map(RegionName.administrativeArea),
            level == .country ? nil : countryCode.map(RegionName.country),
        ].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Nil when the record has no value at this level.
    init?(level: RegionLevel, record: CheckinRecord) {
        let value: String?
        let parentValue: String?
        switch level {
        case .locality:
            value = record.placeLocality
            parentValue = record.placeRegion
        case .administrativeArea:
            value = record.placeRegion
            parentValue = nil
        case .country:
            value = record.placeCountry
            parentValue = nil
        }
        guard let value else { return nil }
        self.level = level
        self.value = value
        self.parentValue = parentValue
        self.countryCode = record.placeCountry
    }

    func matches(_ record: CheckinRecord) -> Bool {
        RegionFilter(level: level, record: record) == self
    }
}

/// A date range from whole days, inclusive at both ends. Either end can be
/// open.
struct DateRangeFilter: Hashable {
    let start: Date?
    let end: Date?
    /// A preset's name, e.g. "2024" or "Last 30 Days". Nil for a custom range.
    let presetName: String?

    func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        if let start, date < calendar.startOfDay(for: start) {
            return false
        }
        if let end,
           let dayAfterEnd = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: end)),
           date >= dayAfterEnd {
            return false
        }
        return true
    }

    /// The chip label: the preset's name, or "Mar 3 – Jun 5, 2025".
    var label: String {
        if let presetName {
            return presetName
        }
        let format = Date.FormatStyle.dateTime.month(.abbreviated).day().year()
        switch (start, end) {
        case let (start?, end?):
            return "\(start.formatted(format)) – \(end.formatted(format))"
        case let (start?, nil):
            return "Since \(start.formatted(format))"
        case let (nil, end?):
            return "Until \(end.formatted(format))"
        case (nil, nil):
            return "Any Time"
        }
    }

    /// Open-ended, so a filter picked yesterday still includes today.
    static func lastDays(_ dayCount: Int, now: Date = Date(), calendar: Calendar = .current) -> DateRangeFilter {
        let start = calendar.date(byAdding: .day, value: -(dayCount - 1), to: now) ?? now
        return DateRangeFilter(start: start, end: nil, presetName: "Last \(dayCount) Days")
    }

    static func year(_ year: Int, calendar: Calendar = .current) -> DateRangeFilter? {
        guard let start = calendar.date(from: DateComponents(year: year, month: 1, day: 1)),
              let end = calendar.date(from: DateComponents(year: year, month: 12, day: 31)) else {
            return nil
        }
        return DateRangeFilter(start: start, end: end, presetName: String(year))
    }
}

struct CheckinSearchFilters: Equatable {
    var dateRange: DateRangeFilter?
    var region: RegionFilter?
    /// An Overture category code, e.g. "coffee_shop".
    var category: String?

    var isEmpty: Bool {
        dateRange == nil && region == nil && category == nil
    }
}

struct RegionOption: Identifiable, Hashable {
    let region: RegionFilter
    let checkinCount: Int

    var id: String { region.id }
}

struct CategoryOption: Identifiable, Hashable {
    let primaryType: String
    let checkinCount: Int

    var id: String { primaryType }
    var name: String { PlaceTypeSymbol.displayName(for: primaryType) }
}

/// Searching the local copy of the user's checkins. Everything runs in
/// memory over the records the view already holds; a few thousand
/// `contains` checks per keystroke take well under a frame.
enum CheckinSearch {
    /// Case- and accent-insensitive form used on both sides of a match, so
    /// "cafe" finds "Café".
    static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// Every word of the query must appear somewhere in the checkin, in any
    /// order: "tacos mission" finds a taqueria in the Mission.
    static func results(
        in records: [CheckinRecord],
        text: String,
        filters: CheckinSearchFilters,
        calendar: Calendar = .current
    ) -> [CheckinRecord] {
        let terms = normalized(text)
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        return records.filter { record in
            if let category = filters.category, record.placePrimaryType != category {
                return false
            }
            if let region = filters.region, !region.matches(record) {
                return false
            }
            if let dateRange = filters.dateRange, !dateRange.contains(record.createdAt, calendar: calendar) {
                return false
            }
            return terms.allSatisfy { record.searchableText.contains($0) }
        }
    }

    /// Every distinct area at each level, most visited first.
    static func regionOptions(in records: [CheckinRecord]) -> [RegionLevel: [RegionOption]] {
        var options: [RegionLevel: [RegionOption]] = [:]
        for level in RegionLevel.allCases {
            var counts: [RegionFilter: Int] = [:]
            for record in records {
                if let region = RegionFilter(level: level, record: record) {
                    counts[region, default: 0] += 1
                }
            }
            options[level] = counts
                .map { RegionOption(region: $0.key, checkinCount: $0.value) }
                .sorted { isOrderedBefore($0, $1) }
        }
        return options
    }

    /// Every category checked in at, most visited first.
    static func categoryOptions(in records: [CheckinRecord]) -> [CategoryOption] {
        var counts: [String: Int] = [:]
        for record in records {
            if let primaryType = record.placePrimaryType {
                counts[primaryType, default: 0] += 1
            }
        }
        return counts
            .map { CategoryOption(primaryType: $0.key, checkinCount: $0.value) }
            .sorted { first, second in
                if first.checkinCount != second.checkinCount {
                    return first.checkinCount > second.checkinCount
                }
                return first.name.localizedStandardCompare(second.name) == .orderedAscending
            }
    }

    /// The years with at least one checkin, newest first.
    static func years(in records: [CheckinRecord], calendar: Calendar = .current) -> [Int] {
        Set(records.map { calendar.component(.year, from: $0.createdAt) }).sorted(by: >)
    }

    private static func isOrderedBefore(_ first: RegionOption, _ second: RegionOption) -> Bool {
        if first.checkinCount != second.checkinCount {
            return first.checkinCount > second.checkinCount
        }
        return first.region.name.localizedStandardCompare(second.region.name) == .orderedAscending
    }
}
