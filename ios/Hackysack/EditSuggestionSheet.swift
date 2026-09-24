//
//  RejectSuggestionSheet.swift
//  Hackysack
//

import CoreLocation
import SwiftUI

/// Shown when the user rejects a suggested checkin. Half-height by default and
/// expandable, it lists the other places found around the visit so the user
/// can either confirm one of them or remove the suggestion altogether.
struct RejectSuggestionSheet: View {
    let suggestion: PendingCheckin
    let onRemove: () -> Void
    let onConfirm: (Place) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedPlaceId: String?

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .safeAreaInset(edge: .bottom) {
                    actionBar
                }
        }
    }

    private var title: String {
        guard let name = suggestion.selectedPlace?.name, !name.isEmpty else { return "Not here?" }
        return "Not \(name)?"
    }

    private var selectedPlace: Place? {
        suggestion.alternativePlaces.first { $0.id == selectedPlaceId }
    }

    /// Distances in the list are measured from where the visit was detected.
    private var visitLocation: CLLocation {
        CLLocation(latitude: suggestion.visit.coordinate.latitude, longitude: suggestion.visit.coordinate.longitude)
    }

    @ViewBuilder
    private var content: some View {
        if suggestion.alternativePlaces.isEmpty {
            ContentUnavailableView {
                Label("No Other Places Nearby", systemImage: "mappin.slash")
            } description: {
                Text("Remove the suggestion if you weren't checking in here.")
            }
        } else {
            List {
                Section {
                    ForEach(suggestion.alternativePlaces) { place in
                        Button {
                            selectedPlaceId = place.id
                        } label: {
                            HStack(spacing: 12) {
                                PlaceRow(place: place, userLocation: visitLocation)
                                if selectedPlaceId == place.id {
                                    Image(systemName: "checkmark")
                                        .font(.body.weight(.semibold))
                                        .foregroundStyle(.blue)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("Were you somewhere else?")
                }
            }
            .listStyle(.plain)
        }
    }

    private var actionBar: some View {
        HStack(spacing: 12) {
            Button(role: .destructive) {
                onRemove()
                dismiss()
            } label: {
                Text("Remove")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            Button {
                guard let selectedPlace else { return }
                onConfirm(selectedPlace)
                dismiss()
            } label: {
                Text("Confirm")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .tint(.blue)
            .disabled(selectedPlace == nil)
        }
        .controlSize(.large)
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

#Preview("Alternatives") {
    Color.clear
        .sheet(isPresented: .constant(true)) {
            RejectSuggestionSheet(suggestion: .preview(), onRemove: {}, onConfirm: { _ in })
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
}

#Preview("No Alternatives") {
    Color.clear
        .sheet(isPresented: .constant(true)) {
            RejectSuggestionSheet(
                suggestion: PendingCheckin(visit: PendingCheckin.preview().visit, candidatePlaces: [.preview]),
                onRemove: {},
                onConfirm: { _ in }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
}
