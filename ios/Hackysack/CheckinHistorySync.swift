//
//  CheckinHistorySync.swift
//  Hackysack
//

import Foundation
import Observation
import SwiftData

/// Keeps a complete local copy of the signed-in user's checkins, for the
/// timeline and search.
///
/// Runs quietly for as long as the signed-in UI is up. It pages through
/// `GET /checkins/sync`, committing each page together with its cursor, so a
/// sync that is killed or loses its connection picks up from the last page
/// it saved. Failures are retried on their own: offline waits for the
/// network to come back, server errors back off exponentially, and 429s wait
/// as long as the server asks. Once caught up it checks again every minute,
/// which is how likes, comments and edits from elsewhere arrive while the app
/// is open; the server counts a like or comment as a change to the checkin.
/// Nothing here shows UI. The search screen reads
/// `status` and the counts to explain what it's working with.
@Observable
final class CheckinHistorySync {
    enum Status: Equatable {
        /// `run()` hasn't started yet.
        case idle
        case syncing
        case upToDate
        /// The most recent request failed. Stays set through retries until
        /// one succeeds, so the search screen shows the error, not a spinner
        /// that keeps restarting.
        case failed(Failure)
    }

    struct Failure: Equatable {
        let message: String
        let isOffline: Bool
        /// False when retrying can't help until something else changes, like
        /// signing in again.
        let willRetryAutomatically: Bool
    }

    private(set) var status: Status = .idle
    /// Checkins stored on this device.
    private(set) var syncedCount = 0
    /// Checkins the server says the user has, as of the last response. Nil
    /// until the first response ever arrives.
    private(set) var totalCount: Int?
    /// True once the whole history has been downloaded at least once. Later
    /// passes only fetch changes, and search stops showing progress for them.
    private(set) var hasCompletedInitialSync = false

    let container: ModelContainer

    @ObservationIgnored private let checkinsAPI: CheckinsAPI
    @ObservationIgnored private let networkMonitor = NetworkMonitor()
    @ObservationIgnored private var syncState: CheckinSyncState?
    /// Every stored record by id, for upserts. The timeline holds all of them
    /// in memory through @Query anyway, so this costs little and saves a
    /// fetch per page.
    @ObservationIgnored private var recordsById: [String: CheckinRecord] = [:]
    @ObservationIgnored private var isSyncRequested = false
    @ObservationIgnored private var wakeUp: CheckedContinuation<Void, Never>?
    /// Distinguishes pauses, so a backoff timer left over from an earlier
    /// pause can't cut a later one short.
    @ObservationIgnored private var pauseGeneration = 0
    @ObservationIgnored private var finishedPassCount = 0

    private static let pageSize = 200
    private static let maximumBackoffSeconds = 300.0
    /// While offline the network monitor is what wakes the sync, so this
    /// is only a safety net in case it misses the reconnect.
    private static let offlineRecheckInterval: Duration = .seconds(60)
    /// How often to look for changes once caught up. An empty changes page
    /// is two small indexed queries, and iOS stops the timer in the
    /// background; coming back to the app asks for a pass straight away.
    private static let pollInterval: Duration = .seconds(60)

    private var modelContext: ModelContext { container.mainContext }

    init(container: ModelContainer, checkinsAPI: CheckinsAPI = CheckinsAPI()) {
        self.container = container
        self.checkinsAPI = checkinsAPI
        rebuildRecordIndex()
        refreshPublishedCounts()
    }

    // MARK: - Driving the sync

    /// Syncs, then waits for something to ask for another pass, until the
    /// calling task is cancelled. Call it from a `.task` on the signed-in UI.
    func run() async {
        networkMonitor.onChange = { [weak self] isConnected in
            // Coming back online should resume right away rather than
            // waiting out the rest of an offline pause.
            guard isConnected, let self, case .failed = self.status else { return }
            self.requestSync()
        }
        networkMonitor.start()
        defer { networkMonitor.stop() }

        var consecutiveFailures = 0
        var hasRestartedFromScratch = false
        while !Task.isCancelled {
            isSyncRequested = false
            do {
                try await syncUntilCaughtUp()
                consecutiveFailures = 0
                hasRestartedFromScratch = false
                status = .upToDate
                finishedPassCount += 1
                await pause(for: Self.pollInterval)
            } catch {
                guard !Task.isCancelled else { return }
                finishedPassCount += 1
                // The server no longer recognizes our cursor. Start over
                // rather than failing forever, but only once in a row, so a
                // server that rejects every cursor can't make us loop.
                if isRejectedCursor(error), !hasRestartedFromScratch {
                    hasRestartedFromScratch = true
                    restartFromScratch()
                    continue
                }
                consecutiveFailures += 1
                let delay = retryDelay(after: error, consecutiveFailures: consecutiveFailures)
                status = .failed(failure(for: error, willRetryAutomatically: delay != nil))
                DevLog.network("Checkin sync failed (attempt \(consecutiveFailures)): \(error)")
                await pause(for: delay)
            }
        }
    }

    /// Asks for another pass as soon as possible. If one is already running,
    /// another follows it, so nothing that changed in the meantime is missed.
    func requestSync() {
        isSyncRequested = true
        endPause(generation: nil)
    }

    /// For pull-to-refresh: asks for a pass and waits, up to a limit, for the
    /// next one to finish. The limit keeps the spinner from hanging through
    /// a long first sync or an offline pause; the pass carries on regardless.
    func refresh() async {
        // A pass already underway may have fetched before whatever the user
        // is refreshing for, so wait for the one after it.
        let target = finishedPassCount + (status == .syncing ? 2 : 1)
        requestSync()
        let deadline = ContinuousClock.now + .seconds(10)
        while finishedPassCount < target, ContinuousClock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// Adds or refreshes one checkin, for checkins the user just created, so
    /// they appear without waiting for the next sync.
    ///
    /// Returns false if it couldn't be saved; the next sync brings it down.
    @discardableResult
    func store(_ checkin: Checkin) -> Bool {
        store([checkin])
    }

    /// Adds or refreshes checkins fetched outside the sync.
    @discardableResult
    func store(_ checkins: [Checkin]) -> Bool {
        guard !checkins.isEmpty else { return true }
        for checkin in checkins {
            upsert(checkin)
        }
        defer { refreshPublishedCounts() }
        do {
            try modelContext.save()
            return true
        } catch {
            DevLog.network("Couldn't store checkins locally: \(error)")
            discardUnsavedChanges()
            return false
        }
    }

    /// Refreshes the stored copy of a checkin that changed on this device (a
    /// like, a comment, an edit). Anyone else's checkin is ignored, as is one
    /// that isn't stored yet; the sync will bring that down whole.
    func updateIfStored(_ checkin: Checkin) {
        guard isStored(checkin.id) else { return }
        store(checkin)
    }

    func isStored(_ checkinId: String) -> Bool {
        recordsById[checkinId] != nil
    }

    /// Stored checkins made within `interval`, in no particular order.
    func checkins(createdIn interval: ClosedRange<Date>) -> [Checkin] {
        recordsById.values
            .filter { interval.contains($0.createdAt) }
            .map(\.checkin)
    }

    /// Every stored checkin, reduced to what the checkin picker ranks by.
    var historyEntries: [CheckinHistoryEntry] {
        recordsById.values.map(CheckinHistoryEntry.init(record:))
    }

    // MARK: - Paging

    private func syncUntilCaughtUp() async throws {
        if case .failed = status {
            // Keep showing the failure until a request actually succeeds.
        } else {
            status = .syncing
        }
        while true {
            try Task.checkCancellation()
            let page = try await checkinsAPI.syncCheckins(
                cursor: currentSyncState().cursor,
                limit: Self.pageSize
            )
            try Task.checkCancellation()
            try apply(page)
            guard page.hasMore else { return }
            status = .syncing
        }
    }

    /// Saves a page and the cursor after it in one transaction, so the cursor
    /// never gets ahead of the records it describes.
    private func apply(_ page: CheckinSyncPage) throws {
        for checkin in page.results {
            upsert(checkin)
        }
        let state = currentSyncState()
        state.cursor = page.nextCursor
        state.totalCount = page.totalCount
        if !page.hasMore {
            state.hasCompletedInitialSync = true
            state.lastSuccessfulSyncAt = Date()
        }
        do {
            try modelContext.save()
        } catch {
            discardUnsavedChanges()
            throw error
        }
        refreshPublishedCounts()
    }

    private func upsert(_ checkin: Checkin) {
        if let record = recordsById[checkin.id] {
            // A page fetched just before an edit can land after the edit's
            // own response. Equal timestamps still apply: a like made here
            // doesn't change updatedAt, nor does a server-side backfill.
            guard checkin.updatedAt >= record.updatedAt else { return }
            record.update(from: checkin)
        } else {
            let record = CheckinRecord(checkin: checkin)
            modelContext.insert(record)
            recordsById[checkin.id] = record
        }
    }

    private func restartFromScratch() {
        let state = currentSyncState()
        state.cursor = nil
        // Records already stored stay put; the backfill just upserts over them.
        try? modelContext.save()
    }

    // MARK: - Local state

    private func currentSyncState() -> CheckinSyncState {
        if let syncState {
            return syncState
        }
        let state: CheckinSyncState
        if let stored = try? modelContext.fetch(FetchDescriptor<CheckinSyncState>()).first {
            state = stored
        } else {
            state = CheckinSyncState()
            modelContext.insert(state)
        }
        syncState = state
        return state
    }

    private func rebuildRecordIndex() {
        let records = (try? modelContext.fetch(FetchDescriptor<CheckinRecord>())) ?? []
        recordsById = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Puts the context back to what is on disk after a failed save, and
    /// drops cached references that may point at rolled-back inserts.
    private func discardUnsavedChanges() {
        modelContext.rollback()
        syncState = nil
        rebuildRecordIndex()
    }

    private func refreshPublishedCounts() {
        let state = currentSyncState()
        syncedCount = recordsById.count
        totalCount = state.totalCount
        hasCompletedInitialSync = state.hasCompletedInitialSync
    }

    // MARK: - Failures

    private func isRejectedCursor(_ error: any Error) -> Bool {
        guard let apiError = error as? APIError,
              case .server(let statusCode, _, _) = apiError else {
            return false
        }
        return statusCode == 400 && syncState?.cursor != nil
    }

    /// How long to wait before trying again, or nil when retrying on a timer
    /// can't help.
    private func retryDelay(after error: any Error, consecutiveFailures: Int) -> Duration? {
        if let apiError = error as? APIError {
            switch apiError {
            case .unauthorized:
                // The auth flow signs the user out if the session is really
                // gone, which tears this sync down with it.
                return nil
            case .rateLimited(let retryAfterSeconds):
                return .seconds(max(retryAfterSeconds, 1))
            case .transport(let underlyingError) where isOffline(underlyingError):
                return Self.offlineRecheckInterval
            default:
                break
            }
        }
        // 2s, 4s, 8s … up to 5 minutes, with jitter so a server coming back
        // from an outage isn't hit by every client at the same instant.
        let exponent = Double(min(consecutiveFailures - 1, 10))
        let seconds = min(2 * pow(2, exponent), Self.maximumBackoffSeconds)
        let jitteredMilliseconds = seconds * 1000 * Double.random(in: 0.8...1.2)
        return .milliseconds(Int(jitteredMilliseconds))
    }

    private func failure(for error: any Error, willRetryAutomatically: Bool) -> Failure {
        let apiError = error as? APIError
        if let apiError, case .transport(let underlyingError) = apiError {
            if isOffline(underlyingError) {
                return Failure(
                    message: "You're offline.",
                    isOffline: true,
                    willRetryAutomatically: willRetryAutomatically
                )
            }
            return Failure(
                message: "Couldn't reach \(AppInfo.name).",
                isOffline: false,
                willRetryAutomatically: willRetryAutomatically
            )
        }
        if let apiError, case .server(let statusCode, _, _) = apiError, statusCode >= 500 {
            return Failure(
                message: "\(AppInfo.name) is having trouble right now.",
                isOffline: false,
                willRetryAutomatically: willRetryAutomatically
            )
        }
        return Failure(
            message: error.localizedDescription,
            isOffline: false,
            willRetryAutomatically: willRetryAutomatically
        )
    }

    /// The monitor's first path update can arrive after the first request
    /// fails at launch, so the error itself counts as evidence too.
    private func isOffline(_ transportError: any Error) -> Bool {
        if !networkMonitor.isConnected {
            return true
        }
        guard let urlError = transportError as? URLError else { return false }
        switch urlError.code {
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
            return true
        default:
            return false
        }
    }

    // MARK: - Waiting

    /// Sleeps until `duration` passes (forever when nil), `requestSync()` is
    /// called, or the task is cancelled, whichever comes first.
    private func pause(for duration: Duration?) async {
        guard !isSyncRequested, !Task.isCancelled else { return }
        pauseGeneration += 1
        let generation = pauseGeneration
        if let duration {
            Task { [weak self] in
                try? await Task.sleep(for: duration)
                self?.endPause(generation: generation)
            }
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                wakeUp = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.endPause(generation: nil)
            }
        }
    }

    /// Ends the current pause. A backoff timer passes the generation it was
    /// started for, so it only ends the pause it belongs to.
    private func endPause(generation: Int?) {
        if let generation, generation != pauseGeneration {
            return
        }
        wakeUp?.resume()
        wakeUp = nil
    }
}
