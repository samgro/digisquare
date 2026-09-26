//
//  DevServerLocator.swift
//  Hackysack
//

import Foundation

/// What one `localhost` port answered when probed: the branch its server
/// runs, or nil when it answered without naming a build.
nonisolated struct DevServerProbe: Equatable, Sendable {
    let port: Int
    let branch: String?
}

#if DEBUG && targetEnvironment(simulator)

/// Finds this build's dev server. Several checkouts run their APIs at once
/// and each takes the first free port from 3000 up, so the port is not known
/// in advance: the app probes the candidate ports and picks the server whose
/// branch is the one this build came from. Runs before the first request and
/// again whenever the build gate is blocking, in case the right server has
/// since come up on another port.
@MainActor
final class DevServerLocator {
    static let shared = DevServerLocator()

    nonisolated static let candidatePorts = 3000..<3010
    nonisolated static let probeTimeout: TimeInterval = 1

    private var locateTask: Task<Void, Never>?

    private init() {}

    /// The first location, shared by every caller that arrives before it is done.
    func ensureLocated() async {
        // Production has a fixed URL. Checked before the task is cached, so a
        // later switch to localhost still gets its first look.
        guard APIEnvironment.server == .localhost else { return }
        if locateTask == nil {
            locateTask = Task { await locate() }
        }
        await locateTask?.value
    }

    /// Probes again, for when the server may have moved or just started.
    func relocate() async {
        guard APIEnvironment.server == .localhost else { return }
        locateTask = Task { await locate() }
        await locateTask?.value
    }

    private func locate() async {
        // An unstamped build cannot tell the servers apart; it keeps the default.
        guard let app = BuildIdentity.app else { return }
        let probes = await withTaskGroup(of: DevServerProbe?.self, returning: [DevServerProbe].self) { group in
            for port in Self.candidatePorts {
                group.addTask { await Self.probe(port: port) }
            }
            var answered: [DevServerProbe] = []
            for await probe in group {
                if let probe {
                    answered.append(probe)
                }
            }
            return answered.sorted { $0.port < $1.port }
        }
        guard let chosen = Self.choose(app: app, among: probes) else {
            DevLog.network("Dev server: nothing answered on ports \(Self.candidatePorts); keeping \(APIEnvironment.devServerPort)")
            return
        }
        APIEnvironment.devServerPort = chosen.port
        DevLog.network("Dev server: using port \(chosen.port) (\(chosen.branch ?? "names no build")); answered: \(probes.map { "\($0.port)=\($0.branch ?? "?")" }.joined(separator: ", "))")
    }

    /// The server on this build's branch, else the first that answered (the
    /// build gate then explains the mismatch), else nil to keep the default.
    nonisolated static func choose(app: BuildIdentity, among probes: [DevServerProbe]) -> DevServerProbe? {
        probes.first { $0.branch == app.branch } ?? probes.first
    }

    nonisolated private static func probe(port: Int) async -> DevServerProbe? {
        var request = URLRequest(url: URL(string: "http://localhost:\(port)/")!)
        request.timeoutInterval = probeTimeout
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let status = try? JSONDecoder().decode(ServerStatus.self, from: data) else {
            return nil
        }
        return DevServerProbe(port: port, branch: status.build?.branch)
    }
}

#else

@MainActor
final class DevServerLocator {
    static let shared = DevServerLocator()
    private init() {}
    func ensureLocated() async {}
    func relocate() async {}
    nonisolated static func choose(app: BuildIdentity, among probes: [DevServerProbe]) -> DevServerProbe? {
        probes.first { $0.branch == app.branch } ?? probes.first
    }
}

#endif
