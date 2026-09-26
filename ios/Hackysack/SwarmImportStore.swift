//
//  SwarmImportStore.swift
//  Hackysack
//

import Foundation
import Observation

/// Whether Swarm is connected and how the latest import is going, shared by
/// the timeline's banner, the empty state, Settings and the import screen, so
/// they all read one answer. Polls the server while an import runs.
@Observable
@MainActor
final class SwarmImportStore {
    private(set) var state: SwarmImportState?
    private(set) var loadError: String?
    /// An import that finished while the app was watching. The banner keeps
    /// showing it for a moment so the user sees it land; a failed one stays
    /// until they open it.
    private(set) var justFinished: SwarmImport?

    /// Called when a running import finishes, so the timeline can reload
    /// with everything it brought in.
    @ObservationIgnored var onImportFinished: () -> Void = {}

    @ObservationIgnored private let swarmImportAPI: SwarmImportAPI
    @ObservationIgnored private var pollingTask: Task<Void, Never>?
    @ObservationIgnored private var dismissalTask: Task<Void, Never>?

    private static let pollInterval: Duration = .seconds(3)
    private static let finishedBannerDuration: Duration = .seconds(6)

    init(swarmImportAPI: SwarmImportAPI = SwarmImportAPI()) {
        self.swarmImportAPI = swarmImportAPI
    }

    var hasLoaded: Bool { state != nil }
    var isConnected: Bool { state?.connected ?? false }
    var latestImport: SwarmImport? { state?.latestImport }

    var runningImport: SwarmImport? {
        guard let latestImport, latestImport.status == .running else { return nil }
        return latestImport
    }

    /// What the timeline shows at its top: the import in progress, or the one
    /// that just ended.
    var bannerImport: SwarmImport? { runningImport ?? justFinished }

    func refresh() async {
        let wasRunning = runningImport
        do {
            state = try await swarmImportAPI.state()
            loadError = nil
        } catch {
            loadError = error.localizedDescription
            return
        }

        if let wasRunning, runningImport == nil {
            onImportFinished()
            if let latestImport, latestImport.id == wasRunning.id {
                justFinished = latestImport
                if latestImport.status == .completed {
                    scheduleBannerDismissal()
                }
            }
        }
        if runningImport != nil {
            startPollingIfNeeded()
        }
    }

    /// Syncs again with the account already connected.
    func startSync() async throws {
        _ = try await swarmImportAPI.startSync()
        justFinished = nil
        await refresh()
    }

    func disconnect() async throws {
        try await swarmImportAPI.disconnect()
        await refresh()
    }

    /// Takes a finished import off the banner, for a tap on it.
    func dismissFinishedBanner() {
        dismissalTask?.cancel()
        justFinished = nil
    }

    private func startPollingIfNeeded() {
        guard pollingTask == nil else { return }
        pollingTask = Task { [weak self] in
            while let self, !Task.isCancelled, self.runningImport != nil {
                try? await Task.sleep(for: Self.pollInterval)
                guard !Task.isCancelled else { break }
                await self.refresh()
            }
            self?.pollingTask = nil
        }
    }

    private func scheduleBannerDismissal() {
        dismissalTask?.cancel()
        dismissalTask = Task { [weak self] in
            try? await Task.sleep(for: Self.finishedBannerDuration)
            guard !Task.isCancelled else { return }
            self?.justFinished = nil
        }
    }
}
