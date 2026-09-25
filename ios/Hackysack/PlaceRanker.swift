//
//  PlaceRanker.swift
//  Hackysack
//

import Foundation

/// The user's position as the ranker sees it: no CoreLocation so the ranker
/// can be driven from fixtures.
nonisolated struct LocationFix: Sendable {
    let latitude: Double
    let longitude: Double
    /// Radius of uncertainty in meters. Negative means Core Location had no
    /// estimate at all.
    let horizontalAccuracy: Double
    let timestamp: Date

    var coordinate: PlaceLocation {
        PlaceLocation(latitude: latitude, longitude: longitude)
    }
}

/// Every tunable in one place. The values were chosen so that each term reads
/// as a log-likelihood in natural-log units: a difference of about 1.1 between
/// two places means one is roughly three times as likely as the other.
nonisolated struct RankingWeights: Sendable {
    /// Strength of the distance penalty. The shape is a Student-t with
    /// `spatialDegreesOfFreedom` degrees of freedom: Gaussian near the fix,
    /// heavy-tailed further out because reported accuracy is optimistic
    /// indoors and between tall buildings.
    var spatial = 2.5
    var spatialDegreesOfFreedom = 3.0
    /// Typical error of a pin's placement, folded into the fix's sigma.
    var pinPlacementError = 12.0
    /// Reported accuracies below this are treated as this.
    var minimumAccuracy = 5.0
    /// How much a blurry fix's inability to resolve a storefront-sized venue
    /// counts against it, and the floor on that penalty.
    var resolution = 0.5
    var resolutionFloor = -2.0
    /// Price a venue pays for its area relative to the fix's blur, per class.
    var containerSize = 0.35
    var destinationSize = 0.15
    /// A destination venue whose recorded grounds contain the fix pays no
    /// size price and earns this instead: standing in an airport, the airport
    /// is the checkin, whatever storefront the fix happens to touch. Sized to
    /// clear the suggestion margin over a storefront nobody has checked in at
    /// (about -0.1 at zero distance), but not one the user is a regular at.
    var insideDestinationGrounds = 1.2
    /// Per log-checkin at the place, from everyone. Nothing at a place nobody
    /// has checked in at yet, so a new venue is ranked on geometry alone.
    var popularity = 0.2
    var history = 1.0
    var historyHalfLifeDays = 90.0
    var timeOfDay = 1.0
    var dayKind = 0.3
    /// Score for a place with no coordinate: still listed, never suggested.
    var missingLocation = -6.0
    /// History places this close to the fix are added as candidates even when
    /// the twenty nearest results did not include them.
    var historyInjectionMinimumRadius = 100.0

    /// The top place must beat the runner-up by this many nats (about 3:1
    /// odds) before the picker skips the list.
    var suggestionMinimumMargin = 1.1
    /// And the chance the user is inside the top place must be at least
    /// this: its own probability plus that of every candidate within its
    /// footprint (a shop in the terminal is still the airport). A storefront
    /// in a building with twenty other listings cannot reach it.
    var suggestionMinimumProbability = 0.5
    var suggestionMaximumAccuracy = 100.0
    var suggestionMaximumFixAgeSeconds = 60.0
    /// The top place must be within the accuracy radius, or this close when
    /// the fix is tighter than this.
    var suggestionMinimumDistanceAllowance = 25.0

    static let standard = RankingWeights()
}

nonisolated struct RankedPlace: Identifiable, Sendable {
    let place: Place
    let score: Double
    /// Softmax of the scores over every candidate: a rough "how sure" for
    /// display and debugging, not the suggestion criterion.
    let probability: Double
    let visitCount: Int
    let effectiveDistance: Double?
    let typePrior: Double

    var id: String { place.id }
}

nonisolated struct PlaceRanking: Sendable {
    let ranked: [RankedPlace]
    /// Set when one venue is so clearly the answer that the picker should go
    /// straight to the compose screen.
    let suggestion: Place?

    static let empty = PlaceRanking(ranked: [], suggestion: nil)
}

/// Orders nearby-search candidates by how likely the user is to be checking
/// in at each one, given the fix's accuracy, each venue's size and type, and
/// the user's own checkin history (how often, at what hour, which days).
///
/// Every scoring term is documented in `RankingWeights`; the design and the
/// fixture scenarios it was tuned against live in `fixtures/ranking/`.
nonisolated struct PlaceRanker: Sendable {
    var weights = RankingWeights.standard

    init(weights: RankingWeights = .standard) {
        self.weights = weights
    }

    func rank(
        candidates: [Place],
        fix: LocationFix,
        history: [CheckinHistoryEntry],
        now: Date,
        calendar: Calendar
    ) -> PlaceRanking {
        let accuracy = max(fix.horizontalAccuracy, weights.minimumAccuracy)
        let sigmaSquared = accuracy * accuracy + weights.pinPlacementError * weights.pinPlacementError
        let sigma = sigmaSquared.squareRoot()
        let fixCoordinate = fix.coordinate
        let statistics = HistoryStatistics(entries: history, now: now, calendar: calendar, halfLifeDays: weights.historyHalfLifeDays)
        let nowHour = calendar.component(.hour, from: now)
        let nowIsWeekend = calendar.isDateInWeekend(now)

        let allCandidates = candidates + injectedHistoryPlaces(
            history: history,
            excluding: Set(candidates.map(\.id)),
            fix: fix
        )

        var scored: [(index: Int, entry: RankedPlace)] = []
        scored.reserveCapacity(allCandidates.count)
        for (index, place) in allCandidates.enumerated() {
            let footprint = PlaceFootprint(for: place)
            let effectiveDistance = footprint.effectiveDistance(from: fixCoordinate, to: place)
            let placeStatistics = statistics.byPlace[place.id]
            // The user's own checkins are direct evidence that this is a
            // place they check in at, whatever its type says about everyone else.
            let typePrior = placeStatistics == nil ? PlaceFootprint.typePrior(for: place) : 0
            var score = 0.0

            if let effectiveDistance {
                let normalized = effectiveDistance * effectiveDistance / (weights.spatialDegreesOfFreedom * sigmaSquared)
                score -= weights.spatial * log(1 + normalized)
            } else {
                score += weights.missingLocation
            }

            // Chance a fix this blurry lands inside a venue this size at all
            // (Rayleigh mass within the footprint radius), softened and floored.
            let ratio = footprint.radius / sigma
            let mass = 1 - exp(-(ratio * ratio) / 2)
            score += max(weights.resolutionFloor, weights.resolution * log(mass))

            // Being anywhere inside a big venue is less specific than being
            // at a storefront; destination venues are canonical checkins so
            // they pay a smaller share of that, and none at all when their
            // recorded grounds say the user is inside.
            let insideRecordedGrounds = footprint.polygon != nil && effectiveDistance == 0
            if footprint.kind == .destination && insideRecordedGrounds {
                score += weights.insideDestinationGrounds
            } else {
                let sizeWeight: Double
                switch footprint.kind {
                case .container: sizeWeight = weights.containerSize
                case .destination: sizeWeight = weights.destinationSize
                case .point: sizeWeight = 0
                }
                score -= sizeWeight * log(1 + ratio * ratio)
            }

            score += weights.popularity * log(1 + Double(place.checkinCount))
            score += typePrior

            var visitCount = 0
            if let placeStatistics, placeStatistics.decayedVisits > 0 {
                visitCount = placeStatistics.visitCount
                score += weights.history * log(1 + placeStatistics.decayedVisits)

                let expectedAtHour = placeStatistics.decayedVisits * HistoryStatistics.kernelMass / 24
                let hourRatio = (placeStatistics.smoothedHours[nowHour] + 0.5) / (expectedAtHour + 0.5)
                score += weights.timeOfDay * Self.clamp(log(hourRatio), -1, 1)

                let observedDays = nowIsWeekend ? placeStatistics.weekendVisits : placeStatistics.weekdayVisits
                let expectedDays = placeStatistics.decayedVisits * (nowIsWeekend ? 2.0 / 7.0 : 5.0 / 7.0)
                score += weights.dayKind * Self.clamp(log((observedDays + 0.5) / (expectedDays + 0.5)), -1, 1)
            }

            scored.append((
                index,
                RankedPlace(
                    place: place,
                    score: score,
                    probability: 0,
                    visitCount: visitCount,
                    effectiveDistance: effectiveDistance,
                    typePrior: typePrior
                )
            ))
        }

        // Ties keep the server's order, which is nearest-first.
        scored.sort { first, second in
            if first.entry.score != second.entry.score {
                return first.entry.score > second.entry.score
            }
            return first.index < second.index
        }

        let maximumScore = scored.first?.entry.score ?? 0
        let total = scored.reduce(0.0) { $0 + exp($1.entry.score - maximumScore) }
        let ranked = scored.map { item in
            RankedPlace(
                place: item.entry.place,
                score: item.entry.score,
                probability: total > 0 ? exp(item.entry.score - maximumScore) / total : 0,
                visitCount: item.entry.visitCount,
                effectiveDistance: item.entry.effectiveDistance,
                typePrior: item.entry.typePrior
            )
        }

        return PlaceRanking(ranked: ranked, suggestion: suggestion(from: ranked, fix: fix, now: now))
    }

    /// The server's order for a typed query (word-start matches, then the
    /// most checked-in, then the nearest) is the right order; the only
    /// adjustment is to float places the user has been to before.
    func orderForQuery(candidates: [Place], history: [CheckinHistoryEntry]) -> [RankedPlace] {
        let visitCounts = history.reduce(into: [String: Int]()) { counts, entry in
            counts[entry.placeId, default: 0] += 1
        }
        let rankedPlaces = candidates.map { place in
            RankedPlace(
                place: place,
                score: 0,
                probability: 0,
                visitCount: visitCounts[place.id] ?? 0,
                effectiveDistance: nil,
                typePrior: 0
            )
        }
        return rankedPlaces.filter { $0.visitCount > 0 } + rankedPlaces.filter { $0.visitCount == 0 }
    }

    // MARK: - Pieces

    private func suggestion(from ranked: [RankedPlace], fix: LocationFix, now: Date) -> Place? {
        guard let top = ranked.first else { return nil }
        let margin = ranked.count > 1 ? top.score - ranked[1].score : Double.infinity
        guard margin >= weights.suggestionMinimumMargin else { return nil }
        guard fix.horizontalAccuracy >= 0, fix.horizontalAccuracy <= weights.suggestionMaximumAccuracy else { return nil }
        guard now.timeIntervalSince(fix.timestamp) <= weights.suggestionMaximumFixAgeSeconds else { return nil }
        guard let effectiveDistance = top.effectiveDistance,
              effectiveDistance <= max(fix.horizontalAccuracy, weights.suggestionMinimumDistanceAllowance) else {
            return nil
        }
        guard top.typePrior == 0 else { return nil }
        guard probabilityOfBeingInside(top, among: ranked) >= weights.suggestionMinimumProbability else {
            return nil
        }
        return top.place
    }

    private func probabilityOfBeingInside(_ venue: RankedPlace, among ranked: [RankedPlace]) -> Double {
        let footprint = PlaceFootprint(for: venue.place)
        // A storefront's radius only absorbs the pin error, so its neighbors
        // are alternatives to it, not parts of it. The venues whose recorded
        // grounds enclose it are not alternatives either: being at Peet's in
        // the terminal is also being in the airport, so the airport's share
        // counts for Peet's rather than against it.
        guard footprint.kind != .point else {
            guard let location = venue.place.location else { return venue.probability }
            return ranked.reduce(0) { total, candidate in
                if candidate.id == venue.id {
                    return total + candidate.probability
                }
                let enclosing = PlaceFootprint(for: candidate.place)
                guard enclosing.polygon != nil, enclosing.effectiveDistance(from: location, to: candidate.place) == 0 else {
                    return total
                }
                return total + candidate.probability
            }
        }
        return ranked.reduce(0) { total, candidate in
            if candidate.id == venue.id {
                return total + candidate.probability
            }
            guard let location = candidate.place.location,
                  footprint.effectiveDistance(from: location, to: venue.place) == 0 else {
                return total
            }
            return total + candidate.probability
        }
    }

    /// In a dense area the twenty nearest results can miss the very place the
    /// user keeps coming back to. Anything from history within a couple of
    /// accuracy radii is added as a candidate built from the stored checkin.
    private func injectedHistoryPlaces(
        history: [CheckinHistoryEntry],
        excluding knownIdentifiers: Set<String>,
        fix: LocationFix
    ) -> [Place] {
        let injectionRadius = max(2 * fix.horizontalAccuracy, weights.historyInjectionMinimumRadius)
        var seen = knownIdentifiers
        var injected: [Place] = []
        for entry in history {
            guard !seen.contains(entry.placeId), let location = entry.location else { continue }
            guard GeoDistance.meters(from: fix.coordinate, to: location) <= injectionRadius else { continue }
            seen.insert(entry.placeId)
            injected.append(
                Place(
                    id: entry.placeId,
                    name: entry.placeName,
                    address: entry.placeAddress,
                    location: location,
                    types: entry.placeTypes,
                    primaryType: entry.placePrimaryType
                )
            )
        }
        return injected
    }

    private static func clamp(_ value: Double, _ low: Double, _ high: Double) -> Double {
        min(max(value, low), high)
    }
}

/// Per-place visit statistics with exponential decay, plus hour-of-day and
/// weekday/weekend histograms for the time affinity terms.
nonisolated struct HistoryStatistics: Sendable {
    struct PlaceStatistics: Sendable {
        var visitCount = 0
        var decayedVisits = 0.0
        /// Visit weight spread over neighboring hours with a triangular kernel
        /// (1, 2/3, 1/3), so an 8:50 visit still counts toward 10:00.
        var smoothedHours = [Double](repeating: 0, count: 24)
        var weekendVisits = 0.0
        var weekdayVisits = 0.0
    }

    /// Total weight the smoothing kernel spreads per visit: 1 + 2·(2/3) + 2·(1/3).
    static let kernelMass = 3.0
    private static let kernel: [(offset: Int, weight: Double)] = [
        (0, 1), (1, 2.0 / 3.0), (-1, 2.0 / 3.0), (2, 1.0 / 3.0), (-2, 1.0 / 3.0),
    ]

    let byPlace: [String: PlaceStatistics]

    init(entries: [CheckinHistoryEntry], now: Date, calendar: Calendar, halfLifeDays: Double) {
        var byPlace: [String: PlaceStatistics] = [:]
        for entry in entries {
            let ageDays = max(0, now.timeIntervalSince(entry.createdAt) / 86_400)
            let weight = pow(0.5, ageDays / halfLifeDays)
            var statistics = byPlace[entry.placeId] ?? PlaceStatistics()
            statistics.visitCount += 1
            statistics.decayedVisits += weight
            let hour = calendar.component(.hour, from: entry.createdAt)
            for (offset, kernelWeight) in Self.kernel {
                statistics.smoothedHours[(hour + offset + 24) % 24] += weight * kernelWeight
            }
            if calendar.isDateInWeekend(entry.createdAt) {
                statistics.weekendVisits += weight
            } else {
                statistics.weekdayVisits += weight
            }
            byPlace[entry.placeId] = statistics
        }
        self.byPlace = byPlace
    }
}
