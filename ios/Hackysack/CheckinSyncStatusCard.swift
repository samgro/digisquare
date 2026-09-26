//
//  CheckinSyncStatusCard.swift
//  Hackysack
//

import SwiftUI

/// Explains what search is working with while the local copy of the user's
/// checkins is incomplete or the latest sync request failed. Renders nothing
/// once everything is synced, so it only takes up space when it matters.
///
/// This is the only place in the app that surfaces the background sync.
struct CheckinSyncStatusCard: View {
    @Environment(CheckinHistorySync.self) private var historySync

    var body: some View {
        switch historySync.status {
        case .failed(let failure):
            card {
                failureContent(failure)
            }
        case .idle, .syncing:
            if !historySync.hasCompletedInitialSync {
                card {
                    progressContent
                }
            }
        case .upToDate:
            EmptyView()
        }
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(HackysackSpacing.medium)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: HackysackRadius.card, style: .continuous)
                    .fill(Color(.secondarySystemBackground))
            )
            .padding(.horizontal, HackysackSpacing.medium)
            .padding(.vertical, HackysackSpacing.small)
            .transition(.opacity)
    }

    private var progressContent: some View {
        VStack(alignment: .leading, spacing: HackysackSpacing.small) {
            Label("Syncing Your Checkins", systemImage: "arrow.triangle.2.circlepath")
                .font(.headline)
            if let totalCount = historySync.totalCount, totalCount > 0 {
                ProgressView(
                    value: Double(min(historySync.syncedCount, totalCount)),
                    total: Double(totalCount)
                )
                Text("\(min(historySync.syncedCount, totalCount).formatted()) of \(totalCount.formatted()) checkins. Results may be incomplete until it finishes.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: HackysackSpacing.small) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Getting started…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func failureContent(_ failure: CheckinHistorySync.Failure) -> some View {
        HStack(alignment: .top, spacing: HackysackSpacing.small + 4) {
            Image(systemName: failure.isOffline ? "wifi.slash" : "exclamationmark.icloud")
                .font(.title3)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("Sync Paused")
                    .font(.headline)
                Text(Self.explanation(for: failure))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let coverage {
                    Text(coverage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Button("Try Again") {
                    historySync.requestSync()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .padding(.top, 4)
            }
        }
    }

    private var syncedCountText: String {
        historySync.syncedCount.formatted()
    }

    /// What search currently covers, e.g. "Searching 1,240 of 3,450 checkins."
    private var coverage: String? {
        guard historySync.syncedCount > 0 else { return nil }
        if !historySync.hasCompletedInitialSync, let totalCount = historySync.totalCount {
            // Checkins made on this device since the last response can put
            // the local count ahead of the server's.
            let syncedCount = min(historySync.syncedCount, totalCount)
            return "Searching \(syncedCount.formatted()) of \(totalCount.formatted()) checkins."
        }
        return "Searching the \(syncedCountText) checkins already on this device."
    }

    static func explanation(for failure: CheckinHistorySync.Failure) -> String {
        if failure.isOffline {
            return "\(failure.message) Syncing picks up where it left off when you're back online."
        }
        if failure.willRetryAutomatically {
            return "\(failure.message) Retrying automatically."
        }
        return failure.message
    }
}
