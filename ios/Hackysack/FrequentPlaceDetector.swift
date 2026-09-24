//
//  FrequentPlaceDetector.swift
//  Hackysack
//

import Foundation

/// Decides whether a detected visit is worth suggesting as a checkin, or whether
/// it is one of the places the user spends most of their life (home, work, a
/// partner's place, a second job) that nobody wants a checkin prompt for
/// several times a day.
///
/// The detector is a pure function of the visit history so it can be unit
/// tested against generated schedules: nothing here touches CoreLocation, the
/// network, the clock, or disk. See `assess(...)` for the rule set.
struct FrequentPlaceDetector {
    struct Configuration {
        /// How far back visit history is considered.
        var historyWindowDays = 56
        /// How far back confirmed checkins count towards the "regular spot" exemption.
        var checkinWindowDays = 90

        /// Two clusters closer than this are the same place.
        var baseClusterRadiusMeters: Double = 150
        /// A visit joins a cluster when it is within `max(base, min(accuracy, maximum))`
        /// of the centroid, so a poor indoor fix still lands at home.
        var maximumJoinRadiusMeters: Double = 300
        /// Visits with worse accuracy than this are too vague to place anywhere.
        var maximumUsableAccuracyMeters: Double = 1000

        /// Completed visits shorter than this are noise (a bus stop, a traffic light).
        var minimumCompletedVisitDuration: TimeInterval = 10 * 60
        /// Leaving and coming back to the same cluster within this gap counts as one stay.
        var maximumGapToBridge: TimeInterval = 2 * 60 * 60

        /// A stitched stay at least this long is a "long stay": the kind of
        /// presence that means home, work, or somewhere similar.
        var longStayDuration: TimeInterval = 5 * 60 * 60
        /// A calendar day touched by a long stay for at least this long is a
        /// "long day". A stay that straddles midnight counts for both days
        /// unless it barely clips one of them.
        var minimumLongStayPresencePerDay: TimeInterval = 2 * 60 * 60
        /// The stretch of the night (as offsets from the local start of day) that
        /// distinguishes sleeping somewhere from working there.
        var nightWindowStartOffset: TimeInterval = 2 * 60 * 60
        var nightWindowEndOffset: TimeInterval = 5 * 60 * 60
        /// Presence overlapping the night window by at least this much makes an overnight day.
        var minimumNightOverlap: TimeInterval = 2 * 60 * 60

        /// A cluster is habitual when it has at least this many long days...
        var minimumLongDays = 8
        /// ...spread over at least this many days (a ten-night hotel stay never qualifies)...
        var minimumSpanDays = 21
        /// ...with at least `minimumLongDaysInDenseWindow` of them inside some
        /// `denseWindowDays`-day stretch. This is the vacation allowance: a fortnight
        /// away doesn't break detection because dense stretches exist on either
        /// side of it, and two long days a week is enough for a partner's place
        /// or a second job.
        var denseWindowDays = 14
        var minimumLongDaysInDenseWindow = 4

        /// A habitual cluster is home when at least this fraction of its long days are overnight.
        var homeOvernightFraction = 0.5

        /// Checkins at one Google place within the cluster needed to keep suggesting it.
        var minimumCheckinsForRegularSpot = 2

        /// One removed suggestion silences the cluster for this long.
        var singleRejectionSnoozeDays = 30
        /// This many removed suggestions silence the cluster for good.
        var permanentRejectionCount = 2
    }

    enum Role: String, Codable, Equatable {
        case home
        case work
    }

    enum Reason: Equatable {
        /// Not a place the user spends long stretches at regularly. Suggest it.
        case notHabitual
        /// Home, work, or another habitual long-stay place. Don't suggest it.
        case habitualPlace(Role)
        /// Habitual or not, the user keeps checking in here on purpose. Suggest it.
        case regularCheckinSpot(placeId: String)
        /// The user removed a suggestion here recently. Don't suggest it.
        case rejectedRecently
        /// The user removed suggestions here repeatedly. Don't suggest it.
        case rejectedRepeatedly
    }

    struct Assessment: Equatable {
        let shouldSuggest: Bool
        let reason: Reason

        var role: Role? {
            if case .habitualPlace(let role) = reason { return role }
            return nil
        }
    }

    /// Everything the detector worked out about one cluster. Exposed so tests can
    /// assert on the intermediate numbers, not just the final decision.
    struct ClusterSummary: Equatable {
        let centroid: GeoCoordinate
        let visitCount: Int
        let longDays: Int
        let overnightLongDays: Int
        let totalDwell: TimeInterval
        let isHabitual: Bool
        let role: Role?
        /// True when the visit passed to `assess`/`clusterSummaries` belongs to this cluster.
        let containsCurrentVisit: Bool

        var overnightFraction: Double {
            longDays == 0 ? 0 : Double(overnightLongDays) / Double(longDays)
        }
    }

    var configuration = Configuration()

    init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    // MARK: - Public API

    /// Assesses a visit, normally on arrival while `visit.departureDate` is still
    /// unknown, since that is the moment a suggestion is useful.
    ///
    /// Precedence: explicit removals win, then places the user regularly checks
    /// into, then the habitual home/work rule, otherwise the visit is suggested.
    func assess(
        visit: VisitRecord,
        history: [VisitRecord],
        checkins: [VisitedPlaceEvent],
        rejections: [RemovedSuggestion],
        now: Date,
        calendar: Calendar
    ) -> Assessment {
        let clusters = analyzedClusters(currentVisit: visit, history: history, now: now, calendar: calendar)
        guard let currentCluster = clusters.first(where: { $0.containsCurrentVisit }) else {
            return Assessment(shouldSuggest: true, reason: .notHabitual)
        }
        let clusterRadius = joinRadius(for: visit)
        let centroid = currentCluster.centroid

        let rejectionsHere = rejections.filter { $0.coordinate.distance(to: centroid) <= clusterRadius }
        if rejectionsHere.count >= configuration.permanentRejectionCount {
            return Assessment(shouldSuggest: false, reason: .rejectedRepeatedly)
        }
        let snoozeStart = now.addingTimeInterval(-days(configuration.singleRejectionSnoozeDays))
        if rejectionsHere.contains(where: { $0.date >= snoozeStart }) {
            return Assessment(shouldSuggest: false, reason: .rejectedRecently)
        }

        let checkinWindowStart = now.addingTimeInterval(-days(configuration.checkinWindowDays))
        let checkinsHere = checkins.filter {
            $0.date >= checkinWindowStart && $0.coordinate.distance(to: centroid) <= clusterRadius
        }
        let checkinsByPlace = Dictionary(grouping: checkinsHere, by: \.placeId)
        let regularPlace = checkinsByPlace
            .filter { $0.value.count >= configuration.minimumCheckinsForRegularSpot }
            .max { left, right in
                left.value.count == right.value.count ? left.key < right.key : left.value.count < right.value.count
            }
        if let regularPlace {
            return Assessment(shouldSuggest: true, reason: .regularCheckinSpot(placeId: regularPlace.key))
        }

        if currentCluster.isHabitual, let role = currentCluster.role {
            return Assessment(shouldSuggest: false, reason: .habitualPlace(role))
        }
        return Assessment(shouldSuggest: true, reason: .notHabitual)
    }

    /// The clusters the detector would build for this history, with their
    /// habitual status and role. `currentVisit` is optional so callers can
    /// inspect a history on its own.
    func clusterSummaries(
        currentVisit: VisitRecord? = nil,
        history: [VisitRecord],
        now: Date,
        calendar: Calendar
    ) -> [ClusterSummary] {
        analyzedClusters(currentVisit: currentVisit, history: history, now: now, calendar: calendar)
            .map { cluster in
                ClusterSummary(
                    centroid: cluster.centroid,
                    visitCount: cluster.members.count,
                    longDays: cluster.longDayOrdinals.count,
                    overnightLongDays: cluster.overnightLongDayCount,
                    totalDwell: cluster.totalDwell,
                    isHabitual: cluster.isHabitual,
                    role: cluster.role,
                    containsCurrentVisit: cluster.containsCurrentVisit
                )
            }
    }

    /// How close a visit has to be to a cluster centroid to belong to it.
    func joinRadius(for visit: VisitRecord) -> Double {
        max(
            configuration.baseClusterRadiusMeters,
            min(visit.horizontalAccuracy, configuration.maximumJoinRadiusMeters)
        )
    }

    // MARK: - Internals

    private struct Interval {
        var start: Date
        var end: Date

        var duration: TimeInterval { end.timeIntervalSince(start) }
    }

    private struct PreparedVisit {
        let record: VisitRecord
        let interval: Interval
        let isCurrent: Bool
    }

    private struct Cluster {
        var centroid: GeoCoordinate
        var members: [PreparedVisit]
        var containsCurrentVisit: Bool { members.contains { $0.isCurrent } }

        // Filled in by `analyze`.
        var dwellByDayOrdinal: [Int: TimeInterval] = [:]
        var nightOverlapByDayOrdinal: [Int: TimeInterval] = [:]
        var longDayOrdinals: [Int] = []
        var overnightLongDayCount = 0
        var totalDwell: TimeInterval = 0
        var isHabitual = false
        var role: Role?
    }

    private func days(_ count: Int) -> TimeInterval {
        TimeInterval(count) * 24 * 60 * 60
    }

    private func analyzedClusters(
        currentVisit: VisitRecord?,
        history: [VisitRecord],
        now: Date,
        calendar: Calendar
    ) -> [Cluster] {
        let windowStart = now.addingTimeInterval(-days(configuration.historyWindowDays))
        let prepared = prepareVisits(currentVisit: currentVisit, history: history, windowStart: windowStart, now: now)
        var clusters = cluster(prepared)
        let referenceDay = calendar.startOfDay(for: windowStart)
        for index in clusters.indices {
            analyze(&clusters[index], referenceDay: referenceDay, calendar: calendar)
        }
        assignRoles(&clusters)
        return clusters
    }

    /// Turns raw records into clipped intervals: drops unusable fixes and short
    /// completed stays, truncates any stale open record at the next arrival so a
    /// lost departure can't inflate a random place into home, and lets only the
    /// current visit run up to `now`.
    private func prepareVisits(
        currentVisit: VisitRecord?,
        history: [VisitRecord],
        windowStart: Date,
        now: Date
    ) -> [PreparedVisit] {
        var records = history.filter { $0.id != currentVisit?.id }
        if let currentVisit {
            records.append(currentVisit)
        }
        records = records
            .filter { $0.horizontalAccuracy <= configuration.maximumUsableAccuracyMeters }
            .filter { ($0.departureDate ?? now) >= windowStart }
            .sorted { left, right in
                if left.arrivalDate != right.arrivalDate {
                    return left.arrivalDate < right.arrivalDate
                }
                return left.id.uuidString < right.id.uuidString
            }

        var prepared: [PreparedVisit] = []
        for (index, record) in records.enumerated() {
            let isCurrent = record.id == currentVisit?.id
            let start = max(record.arrivalDate, windowStart)
            let end: Date
            if let departureDate = record.departureDate {
                end = departureDate
            } else if isCurrent {
                end = now
            } else {
                // A record we never saw a departure for. Assume the stay ended when
                // the next one began; if it is the most recent record, cap it at now.
                let nextArrival = records.dropFirst(index + 1).first?.arrivalDate ?? now
                end = min(nextArrival, now)
            }
            guard end > start else { continue }
            let interval = Interval(start: start, end: end)
            if !isCurrent, interval.duration < configuration.minimumCompletedVisitDuration {
                continue
            }
            prepared.append(PreparedVisit(record: record, interval: interval, isCurrent: isCurrent))
        }
        return prepared
    }

    private func cluster(_ visits: [PreparedVisit]) -> [Cluster] {
        var clusters: [Cluster] = []
        for visit in visits {
            let radius = joinRadius(for: visit.record)
            var bestIndex: Int?
            var bestDistance = Double.infinity
            for (index, candidate) in clusters.enumerated() {
                let distance = candidate.centroid.distance(to: visit.record.coordinate)
                if distance <= radius, distance < bestDistance {
                    bestDistance = distance
                    bestIndex = index
                }
            }
            if let bestIndex {
                clusters[bestIndex].members.append(visit)
                clusters[bestIndex].centroid = Self.centroid(of: clusters[bestIndex].members)
            } else {
                clusters.append(Cluster(centroid: visit.record.coordinate, members: [visit]))
            }
        }
        return merged(clusters)
    }

    /// Greedy assignment can leave two clusters for one place when early visits
    /// were noisy; fold any pair whose centroids ended up within merging range.
    /// The range grows with the members' reported accuracy (up to the join
    /// maximum) so a home seen through 300 m indoor fixes still ends up as one
    /// cluster, while two shops 400 m apart with crisp fixes stay separate.
    private func merged(_ clusters: [Cluster]) -> [Cluster] {
        var clusters = clusters
        var didMerge = true
        while didMerge {
            didMerge = false
            outer: for first in clusters.indices {
                for second in clusters.indices where second > first {
                    if clusters[first].centroid.distance(to: clusters[second].centroid) <= mergeRadius(clusters[first], clusters[second]) {
                        clusters[first].members.append(contentsOf: clusters[second].members)
                        clusters[first].centroid = Self.centroid(of: clusters[first].members)
                        clusters.remove(at: second)
                        didMerge = true
                        break outer
                    }
                }
            }
        }
        return clusters
    }

    private func mergeRadius(_ first: Cluster, _ second: Cluster) -> Double {
        let members = first.members + second.members
        let meanAccuracy = members.reduce(0) { $0 + $1.record.horizontalAccuracy } / Double(members.count)
        return max(configuration.baseClusterRadiusMeters, min(meanAccuracy, configuration.maximumJoinRadiusMeters))
    }

    private static func centroid(of members: [PreparedVisit]) -> GeoCoordinate {
        let count = Double(members.count)
        let latitude = members.reduce(0) { $0 + $1.record.coordinate.latitude } / count
        let longitude = members.reduce(0) { $0 + $1.record.coordinate.longitude } / count
        return GeoCoordinate(latitude: latitude, longitude: longitude)
    }

    /// Stitches the cluster's intervals into stays (bridging short gaps), keeps
    /// only the long ones, then splits those at local midnight to get per-day
    /// presence and per-day overlap with the night window. Short stays never
    /// contribute: five separate hour-long coffee runs are not a long day.
    private func analyze(_ cluster: inout Cluster, referenceDay: Date, calendar: Calendar) {
        let stays = stitched(cluster.members.map(\.interval).sorted { $0.start < $1.start })
            .filter { $0.duration >= configuration.longStayDuration }

        var dwellByDay: [Int: TimeInterval] = [:]
        var nightByDay: [Int: TimeInterval] = [:]
        for stay in stays {
            var dayStart = calendar.startOfDay(for: stay.start)
            while dayStart < stay.end {
                guard let nextDayStart = calendar.date(byAdding: .day, value: 1, to: dayStart) else { break }
                let ordinal = calendar.dateComponents([.day], from: referenceDay, to: dayStart).day ?? 0
                let presence = overlap(stay, Interval(start: dayStart, end: nextDayStart))
                dwellByDay[ordinal, default: 0] += presence
                let night = Interval(
                    start: dayStart.addingTimeInterval(configuration.nightWindowStartOffset),
                    end: dayStart.addingTimeInterval(configuration.nightWindowEndOffset)
                )
                nightByDay[ordinal, default: 0] += overlap(stay, night)
                dayStart = nextDayStart
            }
        }

        cluster.dwellByDayOrdinal = dwellByDay
        cluster.nightOverlapByDayOrdinal = nightByDay
        cluster.totalDwell = dwellByDay.values.reduce(0, +)
        cluster.longDayOrdinals = dwellByDay
            .filter { $0.value >= configuration.minimumLongStayPresencePerDay }
            .map(\.key)
            .sorted()
        cluster.overnightLongDayCount = cluster.longDayOrdinals
            .filter { (nightByDay[$0] ?? 0) >= configuration.minimumNightOverlap }
            .count
        cluster.isHabitual = isHabitual(longDayOrdinals: cluster.longDayOrdinals)
    }

    /// Unions overlapping intervals and bridges gaps shorter than the configured
    /// maximum, so a lunch break away from the office or a quick errand from home
    /// doesn't split one long day into two short ones. A bridged gap counts as
    /// presence, which is what "count as a single long visit" means.
    private func stitched(_ sortedIntervals: [Interval]) -> [Interval] {
        var stays: [Interval] = []
        for interval in sortedIntervals {
            if var last = stays.last, interval.start.timeIntervalSince(last.end) < configuration.maximumGapToBridge {
                last.end = max(last.end, interval.end)
                stays[stays.count - 1] = last
            } else {
                stays.append(interval)
            }
        }
        return stays
    }

    private func overlap(_ first: Interval, _ second: Interval) -> TimeInterval {
        let start = max(first.start, second.start)
        let end = min(first.end, second.end)
        return max(0, end.timeIntervalSince(start))
    }

    private func isHabitual(longDayOrdinals: [Int]) -> Bool {
        guard longDayOrdinals.count >= configuration.minimumLongDays,
              let first = longDayOrdinals.first,
              let last = longDayOrdinals.last,
              last - first >= configuration.minimumSpanDays else {
            return false
        }
        var densest = 0
        var windowStartIndex = 0
        for (index, ordinal) in longDayOrdinals.enumerated() {
            while ordinal - longDayOrdinals[windowStartIndex] >= configuration.denseWindowDays {
                windowStartIndex += 1
            }
            densest = max(densest, index - windowStartIndex + 1)
        }
        return densest >= configuration.minimumLongDaysInDenseWindow
    }

    /// The habitual cluster with the most presence is the anchor and is always
    /// home. Other habitual clusters are home when they are overnight places in
    /// a household that sleeps at night; in a night-shift household (the anchor
    /// itself is not overnight) the overnight places are where the work happens.
    private func assignRoles(_ clusters: inout [Cluster]) {
        let habitualIndices = clusters.indices.filter { clusters[$0].isHabitual }
        guard let anchorIndex = habitualIndices.max(by: { clusters[$0].totalDwell < clusters[$1].totalDwell }) else {
            return
        }
        let anchorIsOvernight = overnightFraction(of: clusters[anchorIndex]) >= configuration.homeOvernightFraction
        for index in habitualIndices {
            if index == anchorIndex {
                clusters[index].role = .home
            } else if overnightFraction(of: clusters[index]) >= configuration.homeOvernightFraction {
                clusters[index].role = anchorIsOvernight ? .home : .work
            } else {
                clusters[index].role = .work
            }
        }
    }

    private func overnightFraction(of cluster: Cluster) -> Double {
        cluster.longDayOrdinals.isEmpty
            ? 0
            : Double(cluster.overnightLongDayCount) / Double(cluster.longDayOrdinals.count)
    }
}
