//
//  BuildGate.swift
//  Hackysack
//

import Foundation
import Observation

#if DEBUG && targetEnvironment(simulator)

/// Tracks whether the dev server this build talks to is from the same
/// checkout. Fed by every response APIClient sees and by an explicit check
/// on launch and foreground, so a switch of servers is caught before the
/// next sign-in, search or checkin can land in the wrong database.
@Observable @MainActor
final class BuildGate {
    static let shared = BuildGate()

    /// Nil when this build was not stamped; the gate then does nothing.
    let app = BuildIdentity.app
    private(set) var server: BuildIdentity?
    private(set) var verdict: BuildIdentity.Verdict = .match

    private init() {}

    /// While true, APIClient sends nothing except the gate's own re-check.
    var isBlocking: Bool { verdict.isBlocking }

    func record(server: BuildIdentity?) {
        guard let app else { return }
        // Every response reports in; only a change is published, so the
        // views watching the gate are not re-rendered per request.
        if self.server != server {
            self.server = server
        }
        let newVerdict = server.map { BuildIdentity.verdict(app: app, server: $0) } ?? .serverUnknown
        if verdict != newVerdict {
            verdict = newVerdict
        }
    }

    /// From a response header; a missing header means the server named no build.
    func record(serverWireValue: String?) {
        record(server: serverWireValue.flatMap { BuildIdentity(wireValue: $0) })
    }

    /// Asks the server what it is running, without a token, so the answer
    /// is known before the welcome screen offers a sign-in.
    func check() async {
        guard app != nil else { return }
        // While blocked, the right server may have come up on another port
        // since the last look; otherwise the first location stands.
        if isBlocking {
            await DevServerLocator.shared.relocate()
        } else {
            await DevServerLocator.shared.ensureLocated()
        }
        do {
            let status: ServerStatus = try await APIClient.shared.request(path: "", authenticated: false, bypassingBuildGate: true)
            record(server: status.build?.identity)
        } catch {
            // The response header or the 409 body already recorded the
            // verdict; a server that is down changes nothing.
        }
    }
}

#else

/// Device and Release builds talk to production, which never enforces a
/// build; this keeps the call sites unconditional.
@MainActor
final class BuildGate {
    static let shared = BuildGate()

    let app: BuildIdentity? = nil
    let server: BuildIdentity? = nil
    let verdict: BuildIdentity.Verdict = .match
    var isBlocking: Bool { false }

    private init() {}

    func record(server: BuildIdentity?) {}
    func record(serverWireValue: String?) {}
    func check() async {}
}

#endif
