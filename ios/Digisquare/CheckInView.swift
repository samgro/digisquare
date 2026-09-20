//
//  CheckInView.swift
//  Digisquare
//

import CoreLocation
import SwiftUI

struct CheckInView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var locationManager: LocationManager

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
                    if locationManager.location != nil {
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
                Button {
                    print("\(place.name) selected")
                } label: {
                    Text(place.name)
                }
                .listRowBackground(Color.white)
            }
            .listStyle(.plain)
            .background(Color.white)
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
                    lat: location.coordinate.latitude,
                    lng: location.coordinate.longitude,
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
}
