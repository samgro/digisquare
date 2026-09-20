//
//  TimelineCheckinRow.swift
//  Digisquare
//

import SwiftUI

/// Maps Google Places primary types to SF Symbols and display names.
enum PlaceTypeSymbol {
    static func systemImageName(for primaryType: String?) -> String {
        guard let primaryType else { return "mappin" }
        switch primaryType {
        case "cafe", "coffee_shop", "bakery", "tea_house":
            return "cup.and.saucer.fill"
        case "bar", "pub", "wine_bar", "night_club":
            return "wineglass.fill"
        case "park", "hiking_area", "national_park", "garden", "dog_park":
            return "tree.fill"
        case "gym", "fitness_center", "sports_complex":
            return "dumbbell.fill"
        case "store", "shopping_mall", "grocery_store", "supermarket", "clothing_store", "convenience_store":
            return "bag.fill"
        case "movie_theater", "performing_arts_theater":
            return "theatermasks.fill"
        case "museum", "art_gallery", "library":
            return "building.columns.fill"
        case "hotel", "lodging":
            return "bed.double.fill"
        case "airport", "train_station", "subway_station", "bus_station", "transit_station":
            return "tram.fill"
        default:
            if primaryType.hasSuffix("restaurant") || primaryType.hasPrefix("meal_") {
                return "fork.knife"
            }
            return "mappin"
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

    var body: some View {
        Image(systemName: PlaceTypeSymbol.systemImageName(for: primaryType))
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(Color.blue)
            .frame(width: 36, height: 36)
            .background(Circle().fill(Color.blue.opacity(0.15)))
    }
}

struct TimelineCheckinRow: View {
    let entry: TimelineEntry
    let onRetry: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            PlaceIconView(primaryType: entry.checkin.placePrimaryType)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .center, spacing: 8) {
                    Text(entry.checkin.placeName)
                        .font(.headline)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                    trailingStatus
                }

                if let message = entry.checkin.message {
                    Text(message)
                        .font(.body)
                }

                detailLine
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var trailingStatus: some View {
        switch entry.syncStatus {
        case .saving:
            ProgressView()
                .controlSize(.small)
        case .saved:
            Text(entry.checkin.createdAt, format: .relative(presentation: .named))
                .font(.caption)
                .foregroundStyle(.secondary)
        case .failed:
            Button(action: onRetry) {
                Label("Retry", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(.red)
        }
    }

    @ViewBuilder
    private var detailLine: some View {
        if entry.syncStatus == .failed {
            Label("Check-in failed", systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
        } else if let placeDetail {
            Text(placeDetail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var placeDetail: String? {
        let typeName = entry.checkin.placePrimaryType.map(PlaceTypeSymbol.displayName)
        let parts = [typeName, entry.checkin.placeAddress].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

#Preview("States") {
    List {
        TimelineCheckinRow(
            entry: TimelineEntry(id: UUID(), draft: nil, checkin: .preview(), syncStatus: .saving),
            onRetry: {}
        )
        TimelineCheckinRow(
            entry: TimelineEntry(id: UUID(), draft: nil, checkin: .preview(), syncStatus: .saved),
            onRetry: {}
        )
        TimelineCheckinRow(
            entry: TimelineEntry(id: UUID(), draft: nil, checkin: .preview(), syncStatus: .failed),
            onRetry: {}
        )
        TimelineCheckinRow(
            entry: TimelineEntry(id: UUID(), draft: nil, checkin: .preview(message: nil, primaryType: "park"), syncStatus: .saved),
            onRetry: {}
        )
    }
    .listStyle(.plain)
}
