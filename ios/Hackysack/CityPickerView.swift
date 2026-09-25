//
//  CityPickerView.swift
//  Hackysack
//

import CoreLocation
import MapKit
import SwiftUI

/// Searchable list of cities for the hometown field, pushed from Edit Profile.
///
/// There is deliberately no way to clear the hometown here: every profile has
/// one, and the API refuses to null it.
struct CityPickerView: View {
    @Binding var hometown: String

    @Environment(LocationManager.self) private var locationManager
    @Environment(\.dismiss) private var dismiss

    @State private var citySearch = CitySearch()
    @State private var query = ""
    @State private var currentCity: String?
    @State private var isLocatingCurrentCity = false
    /// The row being resolved to a display name, so it can show a spinner.
    @State private var resolvingCompletion: MKLocalSearchCompletion?

    private var canUseLocation: Bool {
        switch locationManager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse, .notDetermined:
            return true
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    private var isShowingSearchResults: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        List {
            if isShowingSearchResults {
                ForEach(citySearch.completions, id: \.self) { completion in
                    completionRow(completion)
                }
            } else {
                if canUseLocation {
                    Section {
                        currentLocationRow
                    }
                }
                if !hometown.isEmpty {
                    Section("Hometown") {
                        HStack {
                            Text(hometown)
                            Spacer()
                            Image(systemName: Glyphs.checkmark)
                                .foregroundStyle(Color.accentColor)
                                .fontWeight(.semibold)
                        }
                    }
                }
            }
        }
        .overlay {
            if isShowingSearchResults, !citySearch.isSearching, citySearch.completions.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
        .searchable(
            text: $query,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "Search cities"
        )
        .autocorrectionDisabled()
        .onChange(of: query) { _, newQuery in
            citySearch.search(for: newQuery)
        }
        .navigationTitle("Hometown")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: locationManager.location == nil) {
            await lookUpCurrentCity()
        }
        .disabled(resolvingCompletion != nil)
    }

    private var currentLocationRow: some View {
        Button {
            if let currentCity {
                choose(currentCity)
            } else if locationManager.authorizationStatus == .notDetermined {
                locationManager.requestWhenInUseAuthorization()
            }
        } label: {
            HStack(spacing: HackysackSpacing.medium) {
                Image(systemName: Glyphs.currentLocation)
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Current Location")
                        .foregroundStyle(.primary)
                    if let currentCity {
                        Text(currentCity)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else if locationManager.authorizationStatus == .notDetermined {
                        Text("Allow location access to use where you are")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if isLocatingCurrentCity {
                    ProgressView()
                }
            }
        }
    }

    private func completionRow(_ completion: MKLocalSearchCompletion) -> some View {
        Button {
            Task { await choose(completion) }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(completion.title)
                        .foregroundStyle(.primary)
                    if !completion.subtitle.isEmpty {
                        Text(completion.subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if resolvingCompletion == completion {
                    ProgressView()
                }
            }
        }
    }

    private func lookUpCurrentCity() async {
        guard canUseLocation else { return }
        guard let location = locationManager.location else {
            // Nothing running yet — profile setup, or before the first fix.
            // The task re-runs once a location arrives.
            if locationManager.authorizationStatus == .authorizedWhenInUse
                || locationManager.authorizationStatus == .authorizedAlways {
                locationManager.requestLocation()
            }
            return
        }
        isLocatingCurrentCity = true
        currentCity = await CitySearch.cityName(at: location)
        isLocatingCurrentCity = false
    }

    private func choose(_ completion: MKLocalSearchCompletion) async {
        resolvingCompletion = completion
        let city = await citySearch.cityName(for: completion)
        resolvingCompletion = nil
        choose(city)
    }

    private func choose(_ city: String) {
        hometown = city
        dismiss()
    }
}

#Preview {
    NavigationStack {
        CityPickerView(hometown: .constant("Truckee, CA"))
            .environment(LocationManager())
    }
}
