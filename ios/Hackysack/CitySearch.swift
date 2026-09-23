//
//  CitySearch.swift
//  Hackysack
//

import CoreLocation
import MapKit
import Observation

/// City lookup for the hometown field, backed by MapKit rather than Google.
///
/// Google's edge over Apple is venue data, which the checkin picker needs and
/// a city picker does not. MapKit is free, needs no key or api proxy, runs on
/// the device, and does both halves of this job — autocomplete and turning the
/// current location into a city — so a picked city and a prefilled one come
/// out formatted identically ("San Francisco, CA", "Paris, France").
@Observable
final class CitySearch: NSObject, MKLocalSearchCompleterDelegate {
    @ObservationIgnored private let completer = MKLocalSearchCompleter()
    /// Cleared the moment the query empties, so a late callback for the old
    /// fragment can't repopulate a list the user has already cleared.
    @ObservationIgnored private var hasQuery = false

    private(set) var completions: [MKLocalSearchCompletion] = []
    private(set) var isSearching = false

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = .address
        // Towns and cities only: no street addresses, states or countries.
        completer.addressFilter = MKAddressFilter(including: .locality)
    }

    func search(for query: String) {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            hasQuery = false
            completer.cancel()
            completions = []
            isSearching = false
            return
        }
        hasQuery = true
        isSearching = true
        completer.queryFragment = trimmedQuery
    }

    /// The display name for a picked completion. Resolved through a full
    /// search so it comes back in the same shape as a reverse geocode; the
    /// completion's own title is the fallback if that search fails.
    func cityName(for completion: MKLocalSearchCompletion) async -> String {
        let search = MKLocalSearch(request: MKLocalSearch.Request(completion: completion))
        let mapItem = (try? await search.start())?.mapItems.first
        return mapItem.flatMap(Self.cityName(for:)) ?? completion.title
    }

    /// The city the user is standing in, or nil if it can't be determined.
    static func cityName(at location: CLLocation) async -> String? {
        guard let request = MKReverseGeocodingRequest(location: location) else { return nil }
        do {
            guard let mapItem = try await request.mapItems.first else { return nil }
            return cityName(for: mapItem)
        } catch {
            DevLog.location("Reverse geocode failed: \(error)")
            return nil
        }
    }

    private static func cityName(for mapItem: MKMapItem) -> String? {
        let representations = mapItem.addressRepresentations
        return representations?.cityWithContext ?? representations?.cityName
    }

    // MARK: - MKLocalSearchCompleterDelegate

    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        guard hasQuery else { return }
        completions = completer.results
        isSearching = false
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: any Error) {
        DevLog.location("City search failed: \(error)")
        guard hasQuery else { return }
        completions = []
        isSearching = false
    }
}
