//
//  DebugVisitMenu.swift
//  Hackysack
//

#if DEBUG
import CoreLocation
import SwiftUI

/// Debug builds only: feeds made-up visits around the current location
/// through the real VisitProcessor, so the detector, the Places lookup and the
/// suggestion rows can be tried without waiting for Core Location to report a
/// real stop.
struct DebugVisitMenu: View {
    @Environment(LocationManager.self) private var locationManager
    @EnvironmentObject private var checkinStore: CheckinStore

    @State private var report: String?

    var body: some View {
        Menu {
            Button("Visit Here Now", systemImage: Glyphs.debugVisitHere) {
                run { processor, here in
                    let arrivalDate = Date().addingTimeInterval(-25 * 60)
                    return [await simulateVisit(processor, near: here, northMeters: 0, eastMeters: 0, arrivalDate: arrivalDate, stayedHours: nil)]
                }
            }
            .disabled(locationManager.location == nil)

            Button("Backfill Two Weeks of Visits", systemImage: Glyphs.debugBackfillVisits) {
                run { processor, here in
                    var outcomes: [String] = []
                    // Oldest first, as Core Location would deliver them.
                    for stop in Self.sampleStops(now: Date()) {
                        outcomes.append(
                            await simulateVisit(
                                processor,
                                near: here,
                                northMeters: stop.spot.northMeters,
                                eastMeters: stop.spot.eastMeters,
                                arrivalDate: stop.arrivalDate,
                                stayedHours: stop.stayedHours
                            )
                        )
                    }
                    return outcomes
                }
            }
            .disabled(locationManager.location == nil)

            Button("Clear Suggestions and Visit History", systemImage: Glyphs.delete, role: .destructive) {
                checkinStore.removeAllSuggestions()
                checkinStore.visitHistory.removeAll()
            }
        } label: {
            Label("Debug Visits", systemImage: Glyphs.debugMenu)
        }
        .alert("Simulated Visits", isPresented: .constant(report != nil)) {
            Button("OK") { report = nil }
        } message: {
            Text(report ?? "")
        }
    }

    private func run(_ simulate: @escaping (VisitProcessor, GeoCoordinate) async -> [String]) {
        guard let location = locationManager.location else { return }
        let here = GeoCoordinate(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude)
        let processor = VisitProcessor(visitHistory: checkinStore.visitHistory, checkinStore: checkinStore)
        Task {
            let outcomes = await simulate(processor, here)
            // One line per distinct outcome, so a two-week backfill stays readable.
            let counts = Dictionary(grouping: outcomes, by: { $0 }).mapValues(\.count)
            report = counts
                .sorted { $0.value > $1.value }
                .map { outcome, count in count == 1 ? outcome : "\(count)× \(outcome)" }
                .joined(separator: "\n")
        }
    }

    /// Delivers an arrival and, for a finished stay, its departure, the way
    /// Core Location reports a visit twice.
    private func simulateVisit(
        _ processor: VisitProcessor,
        near here: GeoCoordinate,
        northMeters: Double,
        eastMeters: Double,
        arrivalDate: Date,
        stayedHours: Double?
    ) async -> String {
        let coordinate = here.offset(northMeters: northMeters, eastMeters: eastMeters)
        let arrival = VisitRecord(coordinate: coordinate, horizontalAccuracy: 35, arrivalDate: arrivalDate)
        let arrivalOutcome = await processor.process(arrival, now: arrivalDate.addingTimeInterval(60))
        guard let stayedHours else {
            return describe(arrivalOutcome)
        }
        let departureDate = arrivalDate.addingTimeInterval(stayedHours * 3600)
        let departure = VisitRecord(
            coordinate: coordinate,
            horizontalAccuracy: 35,
            arrivalDate: arrivalDate,
            departureDate: departureDate
        )
        await processor.process(departure, now: departureDate)
        return describe(arrivalOutcome)
    }

    private func describe(_ outcome: VisitProcessor.Outcome) -> String {
        switch outcome {
        case .suggested:
            "Suggested"
        case .suppressed(let reason):
            "Suppressed: \(reason)"
        case .noPlacesFound:
            "No places found (is the API running?)"
        default:
            "\(outcome)"
        }
    }
}

extension DebugVisitMenu {
    /// A spot around the current location, as an offset in meters.
    struct SampleSpot {
        let northMeters: Double
        let eastMeters: Double
    }

    struct SampleStop {
        let spot: SampleSpot
        let arrivalDate: Date
        let stayedHours: Double
    }

    /// Places a few hundred meters away in different directions, so each
    /// lookup finds different shops and none of them bridges into another.
    static let sampleSpots = [
        SampleSpot(northMeters: 400, eastMeters: 0),
        SampleSpot(northMeters: 0, eastMeters: 500),
        SampleSpot(northMeters: -450, eastMeters: -300),
        SampleSpot(northMeters: 650, eastMeters: 600),
        SampleSpot(northMeters: -700, eastMeters: 250),
        SampleSpot(northMeters: 250, eastMeters: -800),
        SampleSpot(northMeters: -300, eastMeters: 900),
    ]

    /// One or two daytime stops a day for the past two weeks, oldest first,
    /// skipping any that would still be in the future today. Deterministic,
    /// so a backfill after a reset looks the same every time.
    static func sampleStops(now: Date, calendar: Calendar = .current) -> [SampleStop] {
        let today = calendar.startOfDay(for: now)
        var stops: [SampleStop] = []
        for daysAgo in stride(from: 13, through: 0, by: -1) {
            guard let day = calendar.date(byAdding: .day, value: -daysAgo, to: today) else { continue }
            let morningHour = 8.5 + Double(daysAgo % 3)
            let afternoonHour = 13 + Double((daysAgo * 2) % 5)
            var daily = [
                SampleStop(
                    spot: sampleSpots[daysAgo % sampleSpots.count],
                    arrivalDate: day.addingTimeInterval(morningHour * 3600),
                    stayedHours: 0.5 + Double(daysAgo % 4) * 0.25
                )
            ]
            if daysAgo % 3 != 0 {
                daily.append(
                    SampleStop(
                        spot: sampleSpots[(daysAgo * 3 + 1) % sampleSpots.count],
                        arrivalDate: day.addingTimeInterval(afternoonHour * 3600),
                        stayedHours: 1 + Double(daysAgo % 3) * 0.5
                    )
                )
            }
            stops += daily.filter { $0.arrivalDate.addingTimeInterval($0.stayedHours * 3600) < now }
        }
        return stops
    }
}

private extension GeoCoordinate {
    func offset(northMeters: Double, eastMeters: Double) -> GeoCoordinate {
        let metersPerDegree = 111_320.0
        return GeoCoordinate(
            latitude: latitude + northMeters / metersPerDegree,
            longitude: longitude + eastMeters / (metersPerDegree * cos(latitude * .pi / 180))
        )
    }
}
#endif
