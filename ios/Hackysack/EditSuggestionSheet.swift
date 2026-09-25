//
//  EditSuggestionSheet.swift
//  Hackysack
//

import CoreLocation
import SwiftUI

/// Shown when the user taps ✕ on a suggested checkin. Half-height by default
/// and expandable, it lists every place found around the visit with the
/// current guess selected, and has the same visibility toggle as the compose
/// screen. Confirm saves the checkin with those choices, Remove drops the
/// suggestion, and dismissing leaves it as it was.
struct EditSuggestionSheet: View {
    let suggestion: PendingCheckin
    let onRemove: () -> Void
    let onConfirm: (_ place: Place, _ visibility: CheckinVisibility) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedPlaceId: String
    @State private var visibility: CheckinVisibility

    init(
        suggestion: PendingCheckin,
        onRemove: @escaping () -> Void,
        onConfirm: @escaping (_ place: Place, _ visibility: CheckinVisibility) -> Void
    ) {
        self.suggestion = suggestion
        self.onRemove = onRemove
        self.onConfirm = onConfirm
        _selectedPlaceId = State(initialValue: suggestion.selectedPlaceId)
        _visibility = State(initialValue: suggestion.visibility)
    }

    var body: some View {
        NavigationStack {
            placeList
                .navigationTitle("Edit Checkin")
                .navigationBarTitleDisplayMode(.inline)
                .safeAreaInset(edge: .bottom) {
                    actionBar
                }
        }
    }

    private var selectedPlace: Place? {
        suggestion.candidatePlaces.first { $0.id == selectedPlaceId }
    }

    /// Distances in the list are measured from where the visit was detected.
    private var visitLocation: CLLocation {
        CLLocation(latitude: suggestion.visit.coordinate.latitude, longitude: suggestion.visit.coordinate.longitude)
    }

    private var placeList: some View {
        List {
            Section {
                ForEach(suggestion.candidatePlaces) { place in
                    Button {
                        selectedPlaceId = place.id
                    } label: {
                        HStack(spacing: 12) {
                            PlaceRow(place: place, userLocation: visitLocation)
                            if selectedPlaceId == place.id {
                                Image(systemName: Glyphs.checkmark)
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(.blue)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selectedPlaceId == place.id ? .isSelected : [])
                }
            } header: {
                Text("Where were you?")
            }
        }
        .listStyle(.plain)
    }

    private var actionBar: some View {
        VStack(spacing: 10) {
            // Mirrors the compose screen's options row.
            HStack {
                CheckinPrivacyToggle(visibility: $visibility)
                Spacer()
            }
            .controlSize(.small)

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
                    onConfirm(selectedPlace, visibility)
                    dismiss()
                } label: {
                    Text("Confirm")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .tint(.blue)
                .disabled(selectedPlace == nil)
            }
            .font(.headline)
            .controlSize(.large)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

#Preview {
    Color.clear
        .sheet(isPresented: .constant(true)) {
            EditSuggestionSheet(suggestion: .preview(visibility: .onlyMe), onRemove: {}, onConfirm: { _, _ in })
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
}
