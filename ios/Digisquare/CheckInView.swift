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

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let errorMessage {
            ContentUnavailableView {
                Label("Couldn't Load Places", systemImage: "exclamationmark.triangle")
            } description: {
                Text(errorMessage)
            }
        } else if isAwaitingFirstResults {
            ProgressView("Finding nearby places…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if places.isEmpty {
            emptyState
        } else {
            placesList
        }
    }

    private var placesList: some View {
        List(places) { place in
            NavigationLink(value: place) {
                PlaceRow(place: place, userLocation: locationManager.location)
            }
            // Without this the borderless style tints the row's text with the
            // accent color, which is why the name currently renders blue.
            .buttonStyle(.plain)
        }
        .listStyle(.plain)
        .scrollDismissesKeyboard(.interactively)
    }

    @ViewBuilder
    private var emptyState: some View {
        if searchText.isEmpty {
            NoPlacesNearbyView()
        } else {
            ContentUnavailableView.search(text: searchText)
        }
    }

    /// True while we are still waiting on the very first set of results, either
    /// because Core Location has not produced a fix yet or because a request is in
    /// flight. Without this the "No Places Nearby" state would appear during the
    /// GPS warm-up and tell the user something that isn't true.
    private var isAwaitingFirstResults: Bool {
        guard places.isEmpty else { return false }
        return isLoading || locationManager.location == nil
    }

    // MARK: - Search

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

/// Extracted so the empty state can be previewed and iterated on without booting
/// the whole screen against a running API.
private struct NoPlacesNearbyView: View {
    var body: some View {
        ContentUnavailableView {
            Label("No Places Nearby", systemImage: "mappin.slash")
        } description: {
            Text("Search for a place by name to check in.")
        }
    }
}

// MARK: - Previews

#Preview("Check In") {
    CheckInView()
        .environmentObject(LocationManager())
        .environmentObject(CheckinStore())
}

#Preview("Check In – With Location") {
    // Note: this drives `search()` against http://localhost:3000, so it shows the
    // error state unless `npm run dev` is running in `api/`. Use the PlaceRow
    // previews to iterate on the row design.
    CheckInView()
        .environmentObject({
            let locationManager = LocationManager()
            locationManager.location = CLLocation(latitude: 37.7749, longitude: -122.4194)
            return locationManager
        }())
}

#Preview("No Places Nearby") {
    NavigationStack {
        NoPlacesNearbyView()
            .navigationTitle("Check In")
            .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview("No Search Results") {
    NavigationStack {
        ContentUnavailableView.search(text: "ramen")
            .navigationTitle("Check In")
            .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview("Error") {
    NavigationStack {
        ContentUnavailableView {
            Label("Couldn't Load Places", systemImage: "exclamationmark.triangle")
        } description: {
            Text(PlacesAPIError.badResponse.localizedDescription)
        }
        .navigationTitle("Check In")
        .navigationBarTitleDisplayMode(.inline)
    }
}
