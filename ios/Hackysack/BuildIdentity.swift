//
//  BuildIdentity.swift
//  Hackysack
//

import Foundation

/// The git branch and commit a build came from, for the dev server gate.
///
/// Several checkouts take turns serving `localhost:3000`, and they share the
/// token secret, so the app cannot tell them apart by their answers alone.
/// A Debug simulator build is stamped with its branch and commit by the
/// "Stamp Git Identity" build phase and sends them with every request; the
/// server names its own in every response. A different branch blocks the
/// app; a different commit on the same branch only earns a banner.
nonisolated struct BuildIdentity: Equatable, Sendable {
    let branch: String
    let commit: String

    /// `branch@commit`, split on the last `@` because a branch may contain one.
    var wireValue: String { "\(branch)@\(commit)" }

    init(branch: String, commit: String) {
        self.branch = branch
        self.commit = commit
    }

    init?(wireValue: String) {
        guard let separator = wireValue.lastIndex(of: "@"),
              separator != wireValue.startIndex,
              wireValue.index(after: separator) != wireValue.endIndex else {
            return nil
        }
        self.init(branch: String(wireValue[..<separator]), commit: String(wireValue[wireValue.index(after: separator)...]))
    }

    enum Verdict: Equatable, Sendable {
        case match
        /// Same branch, another commit: the app is stale but safe to use.
        case commitDiffers
        /// Another checkout entirely: nothing may go through.
        case branchDiffers
        /// The server named no build. A stamped app only ever meets dev
        /// servers, so this is one from before the gate existed: blocked too.
        case serverUnknown

        var isBlocking: Bool { self == .branchDiffers || self == .serverUnknown }
    }

    static func verdict(app: BuildIdentity, server: BuildIdentity) -> Verdict {
        if app.branch != server.branch {
            return .branchDiffers
        }
        return app.commit == server.commit ? .match : .commitDiffers
    }

    /// What this build was made from, or nil when it was not stamped: device
    /// builds, Release builds and test runs, where the gate stays inert.
    static let app: BuildIdentity? = {
        guard let branch = Bundle.main.object(forInfoDictionaryKey: "HackysackGitBranch") as? String,
              let commit = Bundle.main.object(forInfoDictionaryKey: "HackysackGitCommit") as? String,
              !branch.isEmpty, !commit.isEmpty else {
            return nil
        }
        return BuildIdentity(branch: branch, commit: commit)
    }()
}

/// The API's shape for a build, in `GET /` and in a 409 mismatch body.
nonisolated struct BuildIdentityPayload: Decodable, Sendable {
    let branch: String
    let commit: String

    var identity: BuildIdentity { BuildIdentity(branch: branch, commit: commit) }
}

/// The body of the server's 409 when the app is from another branch.
nonisolated struct BuildMismatchBody: Decodable, Sendable {
    let code: String
    let server: BuildIdentityPayload
    let client: BuildIdentityPayload

    static let code = "build_mismatch"
}

/// `GET /`: the server's health line, with its build when it knows one.
nonisolated struct ServerStatus: Decodable, Sendable {
    let status: String
    let build: BuildIdentityPayload?
}
