//
//  CheckInView.swift
//  Hackysack
//

import CoreLocation
import SwiftUI

/// First step of the checkin flow: pick a nearby place. Selecting one pushes
/// `CheckInComposeView`; submitting there saves the checkin and closes this cover.
///
/// Places come back from the API in search order and are re-ranked here with
/// `PlaceRanker` using the fix's accuracy, each venue's size and the user's
/// checkin history. When one venue is clearly the answer the compose screen
/// is pushed immediately, with the ranked list waiting underneath it behind a
/// "Change Location" button.
struct CheckInView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(LocationManager.self) private var locationManager
    @EnvironmentObject private var checkinStore: CheckinStore

    @State private var navigationPath: [Place] = []
    @State private var rankedPlaces: [RankedPlace] = []
    @State private var searchText = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    /// The fix the most recent nearby search used, so a better fix can trigger
    /// another search without every GPS tick doing so.
    @State private var lastSearchedFix: LocationFix?
    @State private var nearbySearchCount = 0
    @State private var appearedAt: Date?
    /// Set once a suggestion has been pushed (or declined), so later re-ranks
    /// never yank the user off the list.
    @State private var hasOfferedSuggestion = false
    @State private var suggestedPlaceId: String?
    @State private var debounceTask: Task<Void, Never>?
    @State private var loadTask: Task<Void, Never>?

    private let placesAPI = PlacesAPI()
    private let ranker = PlaceRanker()

    /// A better fix can arrive seconds after the first, coarse one. Re-searching
    /// is capped so a phone that keeps refining never keeps reloading.
    private static let maximumNearbySearches = 3
    /// Only the initial load may skip the list; after this the user is reading it.
    private static let suggestionWindow: TimeInterval = 3

    var body: some View {
        NavigationStack(path: $navigationPath) {
            content
                .navigationTitle("Check In")
                .navigationBarTitleDisplayMode(.inline)
                .navigationDestination(for: Place.self) { place in
                    let isSuggested = place.id == suggestedPlaceId
                    CheckInComposeView(
                        place: place,
                        onChangeLocation: isSuggested ? showRankedList : nil
                    ) { message in
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
                    debounceTask?.cancel()
                    debounceTask = Task {
                        try? await Task.sleep(for: .milliseconds(300))
                        guard !Task.isCancelled else { return }
                        search()
                    }
                }
                .onAppear {
                    DevLog.location(
                        "CheckInView appeared, has location: \(locationManager.location != nil), "
                        + "status: \(locationManager.authorizationStatus.debugName)"
                    )
                    appearedAt = Date()
                    if let location = locationManager.location {
                        considerNearbySearch(for: location)
                    }
                }
                .onChange(of: locationManager.location) { _, newLocation in
                    guard let newLocation, searchText.isEmpty else { return }
                    considerNearbySearch(for: newLocation)
                }
                .onDisappear {
                    debounceTask?.cancel()
                    loadTask?.cancel()
                    isLoading = false
                }
        }
    }

    /// Pops the compose screen that a confident suggestion pushed, revealing
    /// the ranked list that was waiting underneath it.
    private func showRankedList() {
        navigationPath.removeAll()
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
        } else if rankedPlaces.isEmpty {
            emptyState
        } else {
            placesList
        }
    }

    private var placesList: some View {
        List(rankedPlaces) { rankedPlace in
            NavigationLink(value: rankedPlace.place) {
                PlaceRow(
                    place: rankedPlace.place,
                    userLocation: locationManager.location,
                    visitCount: rankedPlace.visitCount
                )
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
        guard rankedPlaces.isEmpty else { return false }
        return isLoading || locationManager.location == nil
    }

    // MARK: - Search

    /// Runs the nearby search for the first fix, and again when a later fix is
    /// worth it: markedly more accurate, or far enough from the last one that
    /// the earlier results may no longer apply.
    private func considerNearbySearch(for location: CLLocation) {
        let fix = LocationFix(location)
        if let lastSearchedFix {
            guard nearbySearchCount < Self.maximumNearbySearches else { return }
            let previousAccuracy = lastSearchedFix.horizontalAccuracy
            let accuracyImproved = fix.horizontalAccuracy >= 0
                && (previousAccuracy < 0 || fix.horizontalAccuracy * 2 <= previousAccuracy)
            let moved = GeoDistance.meters(from: lastSearchedFix.coordinate, to: fix.coordinate)
                > max(previousAccuracy, 50)
            guard accuracyImproved || moved else { return }
        }
        search(fix: fix)
    }

    private func search() {
        guard let location = locationManager.location else { return }
        search(fix: LocationFix(location))
    }

    private func search(fix: LocationFix) {
        let query = searchText
        if query.isEmpty {
            lastSearchedFix = fix
            nearbySearchCount += 1
        }
        isLoading = true
        errorMessage = nil

        // One request in flight at a time: a stale response must never
        // overwrite a newer one, so the previous task is cancelled outright.
        loadTask?.cancel()
        loadTask = Task {
            do {
                let results = try await placesAPI.searchPlaces(
                    latitude: fix.latitude,
                    longitude: fix.longitude,
                    query: query,
                    horizontalAccuracy: fix.horizontalAccuracy
                )
                guard !Task.isCancelled else { return }
                present(results: results, query: query, fix: fix)
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }

    private func present(results: [Place], query: String, fix: LocationFix) {
        let history = checkinStore.checkinHistory
        guard query.isEmpty else {
            // A typed query is already in relevance order; only float places
            // the user has been to before.
            let visited = Set(history.map(\.googlePlaceId))
            rankedPlaces = ranker.orderForQuery(candidates: results, history: history).map { place in
                RankedPlace(
                    place: place,
                    score: 0,
                    probability: 0,
                    visitCount: visited.contains(place.id) ? history.filter { $0.googlePlaceId == place.id }.count : 0,
                    effectiveDistance: nil,
                    typePrior: 0
                )
            }
            return
        }

        let now = Date()
        let ranking = ranker.rank(
            candidates: results,
            fix: fix,
            history: history,
            now: now,
            calendar: .current
        )
        rankedPlaces = ranking.ranked
        DevLog.location(
            "Ranked \(ranking.ranked.count) places for ±\(Int(fix.horizontalAccuracy))m; "
            + "top: \(ranking.ranked.first?.place.name ?? "none"), suggestion: \(ranking.suggestion?.name ?? "none")"
        )

        guard let suggestion = ranking.suggestion,
              !hasOfferedSuggestion,
              navigationPath.isEmpty,
              let appearedAt,
              now.timeIntervalSince(appearedAt) <= Self.suggestionWindow else {
            return
        }
        hasOfferedSuggestion = true
        suggestedPlaceId = suggestion.id
        // No push animation: the user should land on the compose screen as if
        // it were the first screen, with the list waiting behind Change Location.
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            navigationPath = [suggestion]
        }
    }
}

private extension LocationFix {
    init(_ location: CLLocation) {
        self.init(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            horizontalAccuracy: location.horizontalAccuracy,
            timestamp: location.timestamp
        )
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
        .environment(LocationManager())
        .environmentObject(CheckinStore())
}

#Preview("Check In – With Location") {
    // Note: this drives `search()` against http://localhost:3000, so it shows the
    // error state unless `npm run dev` is running in `api/`. Use the PlaceRow
    // previews to iterate on the row design.
    CheckInView()
        .environment({
            let locationManager = LocationManager()
            locationManager.location = CLLocation(latitude: 37.7749, longitude: -122.4194)
            return locationManager
        }())
        .environmentObject(CheckinStore())
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
            Text(APIError.transport(URLError(.notConnectedToInternet)).localizedDescription)
        }
        .navigationTitle("Check In")
        .navigationBarTitleDisplayMode(.inline)
    }
}
