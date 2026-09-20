//
//  CheckInView.swift
//  Digisquare
//

import CoreLocation
import SwiftUI

/// First step of the check-in flow: pick a nearby place. Selecting one pushes
/// `CheckInComposeView`; submitting there saves the checkin and closes this cover.
struct CheckInView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var locationManager: LocationManager
    @EnvironmentObject private var checkinStore: CheckinStore

    @State private var places: [Place] = []
    @State private var searchText = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var hasLoadedOnce = false
    @State private var searchTask: Task<Void, Never>?

    private let placesAPI = PlacesAPI()

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Check In")
                .navigationBarTitleDisplayMode(.inline)
                .navigationDestination(for: Place.self) { place in
                    CheckInComposeView(place: place) { message in
                        checkinStore.submit(place: place, message: message)
                        // This is the cover's dismiss (CheckInView owns the stack), so it closes
                        // the whole flow rather than popping back to the place list.
                        dismiss()
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(role: .close) {
                            dismiss()
                        }
                    }
                }
                .searchable(text: $searchText)
                .onChange(of: searchText) {
                    searchTask?.cancel()
                    searchTask = Task {
                        try? await Task.sleep(for: .milliseconds(300))
                        guard !Task.isCancelled else { return }
                        search()
                    }
                }
                .onAppear {
                    if !hasLoadedOnce, locationManager.location != nil {
                        search()
                    }
                }
                .onChange(of: locationManager.location) { _, newLocation in
                    if !hasLoadedOnce, newLocation != nil {
                        search()
                    }
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let errorMessage {
            ContentUnavailableView {
                Label("Couldn't Load Places", systemImage: "exclamationmark.triangle")
            } description: {
                Text(errorMessage)
            }
        } else if isLoading && places.isEmpty {
            ProgressView("Finding nearby places…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(places) { place in
                NavigationLink(value: place) {
                    Text(place.name)
                }
            }
            .listStyle(.plain)
        }
    }

    private func search() {
        guard let location = locationManager.location else { return }
        hasLoadedOnce = true
        isLoading = true
        errorMessage = nil

        Task {
            do {
                let results = try await placesAPI.searchPlaces(
                    latitude: location.coordinate.latitude,
                    longitude: location.coordinate.longitude,
                    query: searchText
                )
                places = results
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }
}

#Preview {
    CheckInView()
        .environmentObject(LocationManager())
        .environmentObject(CheckinStore())
}
