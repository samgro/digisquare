//
//  SwarmImportView.swift
//  Hackysack
//

import AuthenticationServices
import SwiftUI

/// Connects a Swarm account and shows the import of its history. The server
/// does the importing; this screen starts it, and the shared store polls for
/// progress so the timeline's banner and this page agree.
struct SwarmImportView: View {
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    @Environment(SwarmImportStore.self) private var swarmImportStore

    @State private var actionError: String?
    @State private var isConnecting = false
    @State private var isConfirmingDisconnect = false

    private let swarmImportAPI = SwarmImportAPI()

    var body: some View {
        List {
            Section {
                Text("Bring your Swarm history into \(AppInfo.name): every checkin, with its photos and notes. Checkins you kept private in Swarm stay visible only to you.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if let latestImport = swarmImportStore.latestImport {
                Section("Latest Import") {
                    SwarmImportProgress(swarmImport: latestImport)
                }
            }

            actionsSection

            if let actionError {
                Section {
                    Text(actionError)
                        .foregroundStyle(.red)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Import from Swarm")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if !swarmImportStore.hasLoaded {
                if let loadError = swarmImportStore.loadError {
                    ContentUnavailableView {
                        Label("Couldn't Load Import", systemImage: Glyphs.loadError)
                    } description: {
                        Text(loadError)
                    } actions: {
                        Button("Try Again") {
                            Task { await swarmImportStore.refresh() }
                        }
                    }
                } else {
                    ProgressView()
                }
            }
        }
        .task {
            await swarmImportStore.refresh()
        }
        .onAppear {
            swarmImportStore.dismissFinishedBanner()
        }
    }

    @ViewBuilder
    private var actionsSection: some View {
        if swarmImportStore.hasLoaded {
            let isRunning = swarmImportStore.runningImport != nil
            Section {
                if swarmImportStore.isConnected {
                    Button("Sync Again") {
                        Task { await syncAgain() }
                    }
                    .disabled(isRunning)

                    Button("Disconnect Swarm", role: .destructive) {
                        isConfirmingDisconnect = true
                    }
                    .confirmationDialog(
                        "Disconnect Swarm?",
                        isPresented: $isConfirmingDisconnect,
                        titleVisibility: .visible
                    ) {
                        Button("Disconnect", role: .destructive) {
                            Task { await disconnect() }
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("Checkins you've already imported stay. You can connect again any time.")
                    }
                } else {
                    Button {
                        Task { await connect() }
                    } label: {
                        HStack {
                            Text("🐝  Connect Swarm")
                            if isConnecting {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isConnecting || isRunning)
                }
            } footer: {
                if swarmImportStore.isConnected {
                    Text("Syncing again picks up checkins made in Swarm since the last import.")
                }
            }
        }
    }

    // MARK: Actions

    /// Sends the user through Foursquare's sign-in. The server finishes the
    /// connection and starts the import before redirecting back here.
    private func connect() async {
        isConnecting = true
        actionError = nil
        defer { isConnecting = false }
        do {
            let authorizationURL = try await swarmImportAPI.authorizationURL()
            // Ephemeral, so there is no "wants to use foursquare.com to sign
            // in" prompt and nothing lingers in the browser afterwards.
            let callbackURL = try await webAuthenticationSession.authenticate(
                using: authorizationURL,
                callback: .customScheme(SwarmImportAPI.callbackScheme),
                preferredBrowserSession: .ephemeral,
                additionalHeaderFields: [:]
            )
            actionError = Self.errorMessage(forCallback: callbackURL)
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            // The user closed the sheet; nothing to say.
        } catch {
            actionError = error.localizedDescription
        }
        await swarmImportStore.refresh()
    }

    private func syncAgain() async {
        actionError = nil
        do {
            try await swarmImportStore.startSync()
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func disconnect() async {
        actionError = nil
        do {
            try await swarmImportStore.disconnect()
        } catch {
            actionError = error.localizedDescription
        }
    }

    /// What went wrong, from the `status` and `reason` the server put on the
    /// callback, or nil when the import started.
    private static func errorMessage(forCallback callbackURL: URL) -> String? {
        let queryItems = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let value = { (name: String) in queryItems.first { $0.name == name }?.value }
        guard value("status") != "started" else { return nil }
        switch value("reason") {
        case "denied":
            return "Swarm wasn't connected because access was declined."
        case "expired":
            return "That took too long. Try connecting again."
        default:
            return "Couldn't connect to Swarm. Try again in a moment."
        }
    }
}

/// Where an import has got to, or how it ended: the same words as the
/// timeline's banner, laid out as a list row.
private struct SwarmImportProgress: View {
    let swarmImport: SwarmImport

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(swarmImport.progressTitle)
                Spacer(minLength: 0)
                switch swarmImport.status {
                case .running:
                    ProgressView()
                        .controlSize(.small)
                case .completed:
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                case .failed:
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }
            if swarmImport.status == .running {
                ThinProgressBar(fraction: swarmImport.progressFraction)
            }
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .contentTransition(.numericText())
        }
        .padding(.vertical, 4)
        .animation(.easeInOut(duration: 0.6), value: swarmImport.progressFraction)
    }

    private var detail: String {
        guard swarmImport.status == .completed, let finishedAt = swarmImport.finishedAt else {
            return swarmImport.progressDetail
        }
        return "\(swarmImport.progressDetail) · finished \(finishedAt.formatted(date: .abbreviated, time: .shortened))"
    }
}

#Preview {
    NavigationStack {
        SwarmImportView()
    }
    .environment(SwarmImportStore())
}
