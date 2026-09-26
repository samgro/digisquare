//
//  CheckinSearchFilterBar.swift
//  Hackysack
//

import SwiftUI

enum SearchFilterKind: String, Identifiable {
    case date
    case region
    case category

    var id: String { rawValue }
}

/// The row of filter chips pinned under the search field. Each chip
/// opens its picker, and a chip with a filter applied turns prominent and
/// shows its value.
struct CheckinSearchFilterBar: View {
    @Binding var filters: CheckinSearchFilters
    let onSelect: (SearchFilterKind) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            GlassEffectContainer(spacing: HackysackSpacing.small) {
                HStack(spacing: HackysackSpacing.small) {
                    chip(
                        .date,
                        title: "Date",
                        value: filters.dateRange?.label,
                        systemImage: "calendar"
                    )
                    chip(
                        .region,
                        title: "Region",
                        value: filters.region?.name,
                        systemImage: "map"
                    )
                    chip(
                        .category,
                        title: "Category",
                        value: filters.category.map { PlaceTypeSymbol.displayName(for: $0) },
                        systemImage: "tag"
                    )
                    if !filters.isEmpty {
                        Button("Clear") {
                            withAnimation {
                                filters = CheckinSearchFilters()
                            }
                        }
                        .font(.subheadline.weight(.medium))
                        .buttonStyle(.glass)
                    }
                }
                .padding(.horizontal, HackysackSpacing.medium)
                .padding(.vertical, HackysackSpacing.small)
            }
        }
        .scrollIndicators(.hidden)
        .animation(.default, value: filters)
    }

    @ViewBuilder
    private func chip(
        _ kind: SearchFilterKind,
        title: String,
        value: String?,
        systemImage: String
    ) -> some View {
        let button = Button {
            onSelect(kind)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                Text(value ?? title)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
            }
            .font(.subheadline.weight(.medium))
        }
        .accessibilityLabel(value.map { "\(title): \($0)" } ?? title)

        if value != nil {
            button.buttonStyle(.glassProminent)
        } else {
            button.buttonStyle(.glass)
        }
    }
}

#Preview {
    @Previewable @State var filters = CheckinSearchFilters(category: "coffee_shop")
    CheckinSearchFilterBar(filters: $filters) { _ in }
}
