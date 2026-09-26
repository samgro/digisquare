//
//  CheckInView.swift
//  Hackysack
//

import CoreLocation
import SwiftUI

/// Where the checkin flow can go from the place list.
enum CheckInRoute: Hashable {
    /// Write a message for this place and submit.
    case compose(Place)
    /// Add a venue the data does not have, then compose for it.
    case createPlace
}

/// First step of the checkin flow: pick a nearby place. Selecting one pushes
/// `CheckInComposeView`; submitting there saves the checkin and closes this cover.
/// A place that is not listed can be added from the list's last row or from
/// the empty states, which pushes `CreatePlaceView` instead.
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

    @State private var navigationPath: [CheckInRoute] = []
    @State private var rankedPlaces: [RankedPlace] = []
    /// Whether the server has place data for the area, from the last search.
    @State private var coverage: PlaceCoverage = .ready
    @State private var searchText = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    /// The fix the most recent nearby search used, so a better fix can trigger
    /// another search without every GPS tick doing so.
    @State private var lastSearchedFix: LocationFix?
    @State private var nearbySearchCount = 0
    /// When the ranked list was first on screen. A suggestion may only skip
    /// the list before this or shortly after it, never once the user is reading.
    @State private var listFirstShownAt: Date?
    /// Set once a suggestion has been pushed (or declined), so later re-ranks
    /// never yank the user off the list.
    @State private var hasOfferedSuggestion = false
    @State private var suggestedPlaceId: String?
    @State private var debounceTask: Task<Void, Never>?
    @State private var loadTask: Task<Void, Never>?
    /// Searches again each time the server's estimate for an area elapses,
    /// for as long as the area is still being fetched.
    @State private var coverageRetryTask: Task<Void, Never>?
    /// How many of those retries have come back still importing, so the
    /// copy stops promising "about a minute" once that has passed.
    @State private var coverageRetryCount = 0

    private let placesAPI = PlacesAPI()
    private let ranker = PlaceRanker()

    /// A better fix can arrive seconds after the first, coarse one. Re-searching
    /// is capped so a phone that keeps refining never keeps reloading.
    private static let maximumNearbySearches = 3
    /// A better fix arriving this soon after the list first appears may still
    /// skip it; after this the user is reading it.
    private static let suggestionWindow: TimeInterval = 3

    var body: some View {
        NavigationStack(path: $navigationPath) {
            content
                .navigationTitle("Check In")
                .navigationBarTitleDisplayMode(.inline)
                .navigationDestination(for: CheckInRoute.self) { route in
                    switch route {
                    case .compose(let place):
                        composeView(for: place)
                    case .createPlace:
                        CreatePlaceView(initialName: searchText) { place in
                            // The new venue replaces the form on the stack, so
                            // Back from compose returns to the list, not the form.
                            navigationPath = [.compose(place)]
                        }
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
                    if let location = locationManager.location {
                        considerNearbySearch(for: location)
                    }
                }
                .onChange(of: locationManager.location) { _, newLocation in
                    guard let newLocation, searchText.isEmpty else { return }
                    considerNearbySearch(for: newLocation)
                }
                .onChange(of: navigationPath) {
                    // Once the user has left the suggested compose screen,
                    // picking that place from the list is an ordinary choice.
                    if navigationPath.isEmpty {
                        suggestedPlaceId = nil
                    }
                }
                .onDisappear {
                    debounceTask?.cancel()
                    loadTask?.cancel()
                    coverageRetryTask?.cancel()
                    isLoading = false
                }
        }
    }

    private func composeView(for place: Place) -> CheckInComposeView {
        var onChangeLocation: (() -> Void)?
        if place.id == suggestedPlaceId {
            onChangeLocation = showRankedList
        }
        return CheckInComposeView(place: place, onChangeLocation: onChangeLocation) { message, visibility, photos in
            checkinStore.submit(place: place, message: message, visibility: visibility, photos: photos)
            // This is the cover's dismiss (CheckInView owns the stack), so it closes
            // the whole flow rather than popping back to the place list.
            dismiss()
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
                Label("Couldn't Load Places", systemImage: Glyphs.loadError)
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
        List {
            if coverage.status == .importing {
                CoverageBanner(coverage: coverage, isTakingLonger: coverageRetryCount > 0)
            }
            ForEach(rankedPlaces) { rankedPlace in
                NavigationLink(value: CheckInRoute.compose(rankedPlace.place)) {
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
            NavigationLink(value: CheckInRoute.createPlace) {
                Label("Can't find it? Add a place", systemImage: "plus.circle")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.accentColor)
            }
        }
        .listStyle(.plain)
        .scrollDismissesKeyboard(.interactively)
    }

    @ViewBuilder
    private var emptyState: some View {
        switch coverage.status {
        case .importing:
            AreaLoadingView(
                coverage: coverage,
                isTakingLonger: coverageRetryCount > 0,
                onRetry: search,
                onAddPlace: { navigationPath.append(.createPlace) }
            )
        case .missing, .failed:
            NoAreaDataView(coverage: coverage, onAddPlace: { navigationPath.append(.createPlace) })
        case .ready:
            if searchText.isEmpty {
                NoPlacesNearbyView {
                    navigationPath.append(.createPlace)
                }
            } else {
                ContentUnavailableView {
                    Label("No Results for \"\(searchText)\"", systemImage: "magnifyingglass")
                } description: {
                    Text("Check the spelling, or add it as a new place.")
                } actions: {
                    addPlaceButton
                }
            }
        }
    }

    private var addPlaceButton: some View {
        Button {
            navigationPath.append(.createPlace)
        } label: {
            Label("Add a Place", systemImage: "plus")
        }
        .buttonStyle(.borderedProminent)
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
                let searchResult = try await placesAPI.searchPlaces(
                    latitude: fix.latitude,
                    longitude: fix.longitude,
                    query: query,
                    horizontalAccuracy: fix.horizontalAccuracy
                )
                guard !Task.isCancelled else { return }
                coverage = searchResult.coverage
                if coverage.status != .importing {
                    coverageRetryCount = 0
                }
                scheduleCoverageRetry()
                present(results: searchResult.results, query: query, fix: fix)
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }

    /// While the server is fetching the area, search again when its estimate
    /// elapses (and again after that, while it is still fetching), so a user
    /// who waits on this screen sees the places appear without tapping
    /// anything.
    private func scheduleCoverageRetry() {
        coverageRetryTask?.cancel()
        guard coverage.status == .importing else { return }
        let delay = max(coverage.estimatedSecondsRemaining ?? 60, 30)
        coverageRetryTask = Task {
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            coverageRetryCount += 1
            search()
        }
    }

    private func present(results: [Place], query: String, fix: LocationFix) {
        let now = Date()
        let listShownAt = listFirstShownAt ?? now
        if !results.isEmpty, listFirstShownAt == nil {
            listFirstShownAt = now
        }

        let history = checkinStore.checkinHistory
        guard query.isEmpty else {
            rankedPlaces = ranker.orderForQuery(candidates: results, history: history)
            return
        }

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
              now.timeIntervalSince(listShownAt) <= Self.suggestionWindow else {
            return
        }
        hasOfferedSuggestion = true
        suggestedPlaceId = suggestion.id
        // No push animation: the user should land on the compose screen as if
        // it were the first screen, with the list waiting behind Change Location.
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            navigationPath = [.compose(suggestion)]
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

/// Shown while the server fetches place data for an area nobody has searched
/// from before. The wait comes from the server's own estimate.
private struct AreaLoadingView: View {
    let coverage: PlaceCoverage
    /// The estimate has already passed once; stop quoting it.
    var isTakingLonger = false
    let onRetry: () -> Void
    let onAddPlace: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Getting Places for This Area", systemImage: "arrow.down.circle.dotted")
        } description: {
            Text(
                isTakingLonger
                    ? "Still downloading places for this area. A dense city can take a few minutes; "
                        + "we'll keep checking."
                    : "This is the first search around here, so we're downloading places for it. "
                        + "Try again in about \(coverage.waitDescription ?? "a few minutes")."
            )
        } actions: {
            Button(action: onRetry) {
                Label("Try Again", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent)
            Button(action: onAddPlace) {
                Label("Add a Place", systemImage: "plus")
            }
        }
    }
}

/// The server has no data for the area and is not fetching it: the user is
/// over their allowance, the fetch failed, or they are signed out. The copy
/// never says how long a limit lasts.
private struct NoAreaDataView: View {
    let coverage: PlaceCoverage
    let onAddPlace: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("No Place Data Here Yet", systemImage: "map")
        } description: {
            if coverage.status == .failed {
                Text("Downloading this area didn't work. We'll try again later; meanwhile you can add the place yourself.")
            } else {
                Text("We can't get places for this area right now. Try again later, or add the place yourself.")
            }
        } actions: {
            Button(action: onAddPlace) {
                Label("Add a Place", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

/// A thin row above the list while more places for the area are on the way.
private struct CoverageBanner: View {
    let coverage: PlaceCoverage
    var isTakingLonger = false

    var body: some View {
        Label(
            isTakingLonger
                ? "More places for this area are still on the way."
                : "More places for this area are on the way (about \(coverage.waitDescription ?? "a few minutes")).",
            systemImage: "arrow.down.circle.dotted"
        )
        .font(.footnote)
        .foregroundStyle(.secondary)
        .listRowBackground(Color.clear)
    }
}

/// Extracted so the empty state can be previewed and iterated on without booting
/// the whole screen against a running API.
private struct NoPlacesNearbyView: View {
    var onAddPlace: () -> Void = {}

    var body: some View {
        ContentUnavailableView {
            Label("No Places Nearby", systemImage: Glyphs.noPlacesNearby)
        } description: {
            Text("Search for a place by name, or add one.")
        } actions: {
            Button(action: onAddPlace) {
                Label("Add a Place", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

// MARK: - Previews

#Preview("Check In") {
    CheckInView()
        .environment(LocationManager())
        .environmentObject(CheckinStore.inMemory())
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
        .environmentObject(CheckinStore.inMemory())
}

#Preview("No Places Nearby") {
    NavigationStack {
        NoPlacesNearbyView()
            .navigationTitle("Check In")
            .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview("Area Loading") {
    NavigationStack {
        AreaLoadingView(
            coverage: PlaceCoverage(status: .importing, estimatedSecondsRemaining: 150),
            onRetry: {},
            onAddPlace: {}
        )
        .navigationTitle("Check In")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview("No Area Data") {
    NavigationStack {
        NoAreaDataView(
            coverage: PlaceCoverage(status: .missing, estimatedSecondsRemaining: nil),
            onAddPlace: {}
        )
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
            Label("Couldn't Load Places", systemImage: Glyphs.loadError)
        } description: {
            Text(APIError.transport(URLError(.notConnectedToInternet)).localizedDescription)
        }
        .navigationTitle("Check In")
        .navigationBarTitleDisplayMode(.inline)
    }
}
