//
//  SearchFilterSheets.swift
//  Hackysack
//

import SwiftUI

/// Toolbar shared by the filter pickers: close on the leading side, and a
/// Clear button while a filter is applied.
private struct FilterSheetToolbar: ToolbarContent {
    let isFilterApplied: Bool
    let onClear: () -> Void
    let onClose: () -> Void

    var body: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button(role: .close, action: onClose)
        }
        if isFilterApplied {
            ToolbarItem(placement: .confirmationAction) {
                Button("Clear", action: onClear)
            }
        }
    }
}

/// A picker row: title, optional subtitle, and either a checkmark or how
/// many checkins it covers.
private struct FilterOptionRow<Icon: View>: View {
    let title: String
    var subtitle: String?
    let checkinCount: Int
    let isSelected: Bool
    @ViewBuilder var icon: () -> Icon

    var body: some View {
        HStack(spacing: HackysackSpacing.medium) {
            icon()
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .foregroundStyle(.primary)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
            } else {
                Text(checkinCount.formatted())
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Date

struct DateRangeFilterSheet: View {
    @Binding var selection: DateRangeFilter?
    let years: [Int]

    @Environment(\.dismiss) private var dismiss
    @State private var customStart: Date
    @State private var customEnd: Date

    init(selection: Binding<DateRangeFilter?>, years: [Int]) {
        _selection = selection
        self.years = years
        let now = Date()
        let monthAgo = Calendar.current.date(byAdding: .month, value: -1, to: now) ?? now
        _customStart = State(initialValue: selection.wrappedValue?.start ?? monthAgo)
        _customEnd = State(initialValue: selection.wrappedValue?.end ?? now)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    presetRow(.lastDays(7))
                    presetRow(.lastDays(30))
                    presetRow(.lastDays(90))
                }

                if !years.isEmpty {
                    Section("Years") {
                        ForEach(years, id: \.self) { year in
                            if let filter = DateRangeFilter.year(year) {
                                presetRow(filter)
                            }
                        }
                    }
                }

                Section("Custom Range") {
                    DatePicker("From", selection: $customStart, in: ...customEnd, displayedComponents: .date)
                    DatePicker("To", selection: $customEnd, in: customStart..., displayedComponents: .date)
                    Button("Show This Range") {
                        apply(DateRangeFilter(start: customStart, end: customEnd, presetName: nil))
                    }
                }
            }
            .navigationTitle("Date")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                FilterSheetToolbar(
                    isFilterApplied: selection != nil,
                    onClear: { apply(nil) },
                    onClose: { dismiss() }
                )
            }
        }
    }

    private func presetRow(_ filter: DateRangeFilter) -> some View {
        Button {
            apply(filter)
        } label: {
            HStack {
                Text(filter.label)
                    .foregroundStyle(.primary)
                Spacer()
                // Presets are matched by name: "Last 7 Days" picked yesterday
                // is still the same choice today.
                if selection?.presetName == filter.presetName {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .contentShape(Rectangle())
        }
    }

    private func apply(_ filter: DateRangeFilter?) {
        selection = filter
        dismiss()
    }
}

// MARK: - Region

struct RegionFilterSheet: View {
    @Binding var selection: RegionFilter?
    let options: [RegionLevel: [RegionOption]]

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    var body: some View {
        NavigationStack {
            List {
                ForEach(RegionLevel.allCases) { level in
                    let levelOptions = matchingOptions(at: level)
                    if !levelOptions.isEmpty {
                        Section(level.pluralTitle) {
                            ForEach(levelOptions) { option in
                                Button {
                                    selection = option.region
                                    dismiss()
                                } label: {
                                    FilterOptionRow(
                                        title: option.region.name,
                                        subtitle: option.region.subtitle,
                                        checkinCount: option.checkinCount,
                                        isSelected: selection == option.region
                                    ) {
                                        Image(systemName: level.systemImageName)
                                            .foregroundStyle(.secondary)
                                            .frame(width: 24)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .overlay {
                if RegionLevel.allCases.allSatisfy({ matchingOptions(at: $0).isEmpty }) {
                    if searchText.isEmpty {
                        ContentUnavailableView(
                            "No Regions Yet",
                            systemImage: "map",
                            description: Text("Neighborhoods, cities and countries show up here as your checkins sync.")
                        )
                    } else {
                        ContentUnavailableView.search(text: searchText)
                    }
                }
            }
            .searchable(
                text: $searchText,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Neighborhoods, cities, countries"
            )
            .navigationTitle("Region")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                FilterSheetToolbar(
                    isFilterApplied: selection != nil,
                    onClear: {
                        selection = nil
                        dismiss()
                    },
                    onClose: { dismiss() }
                )
            }
        }
    }

    private func matchingOptions(at level: RegionLevel) -> [RegionOption] {
        let levelOptions = options[level] ?? []
        let query = CheckinSearch.normalized(searchText.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !query.isEmpty else { return levelOptions }
        return levelOptions.filter { CheckinSearch.normalized($0.region.name).contains(query) }
    }
}

// MARK: - Category

struct CategoryFilterSheet: View {
    @Binding var selection: String?
    let options: [CategoryOption]

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(options) { option in
                Button {
                    selection = option.primaryType
                    dismiss()
                } label: {
                    FilterOptionRow(
                        title: option.name,
                        checkinCount: option.checkinCount,
                        isSelected: selection == option.primaryType
                    ) {
                        PlaceIconView(primaryType: option.primaryType)
                    }
                }
            }
            .overlay {
                if options.isEmpty {
                    ContentUnavailableView(
                        "No Categories Yet",
                        systemImage: "tag",
                        description: Text("Categories show up here as your checkins sync.")
                    )
                }
            }
            .navigationTitle("Category")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                FilterSheetToolbar(
                    isFilterApplied: selection != nil,
                    onClear: {
                        selection = nil
                        dismiss()
                    },
                    onClose: { dismiss() }
                )
            }
        }
    }
}

#Preview("Date") {
    @Previewable @State var selection = DateRangeFilter.year(2025)
    DateRangeFilterSheet(selection: $selection, years: [2026, 2025, 2024])
}
