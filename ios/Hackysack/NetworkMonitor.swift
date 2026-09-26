//
//  NetworkMonitor.swift
//  Hackysack
//

import Foundation
import Network
import Observation

/// Whether the device has a usable network path, so the checkin sync can
/// tell "offline" apart from "the server is down" and resume the moment a
/// connection comes back instead of waiting out a backoff.
@Observable
final class NetworkMonitor {
    /// Optimistic until the first path update, so nothing is shown as
    /// offline during the instant before the monitor reports in.
    private(set) var isConnected = true

    /// Called on the main actor whenever `isConnected` changes.
    @ObservationIgnored var onChange: ((Bool) -> Void)?

    @ObservationIgnored private var pathMonitor: NWPathMonitor?

    func start() {
        guard pathMonitor == nil else { return }
        let pathMonitor = NWPathMonitor()
        pathMonitor.pathUpdateHandler = Self.makePathUpdateHandler { [weak self] isConnected in
            guard let self else { return }
            Task { @MainActor in
                self.update(isConnected: isConnected)
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "NetworkMonitor"))
        self.pathMonitor = pathMonitor
    }

    func stop() {
        pathMonitor?.cancel()
        pathMonitor = nil
    }

    private func update(isConnected: Bool) {
        guard isConnected != self.isConnected else { return }
        self.isConnected = isConnected
        onChange?(isConnected)
    }

    /// Built outside the main actor on purpose. The monitor calls this on its
    /// own queue; a closure written inline above would be inferred as
    /// main-actor isolated and then run off the main thread.
    private nonisolated static func makePathUpdateHandler(
        _ report: @escaping @Sendable (Bool) -> Void
    ) -> @Sendable (NWPath) -> Void {
        { path in report(path.status == .satisfied) }
    }
}
