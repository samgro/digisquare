//
//  BuildIdentityTests.swift
//  HackysackTests
//

import Testing
@testable import Hackysack

@Suite("Build identity")
struct BuildIdentityTests {
    @Test("Round-trips the wire format, splitting on the last @")
    func wireFormat() {
        let identity = BuildIdentity(branch: "sam@work/gate", commit: "7e1389e")
        #expect(identity.wireValue == "sam@work/gate@7e1389e")
        #expect(BuildIdentity(wireValue: "sam@work/gate@7e1389e") == identity)
    }

    @Test("Rejects values without both parts")
    func rejectsGarbage() {
        #expect(BuildIdentity(wireValue: "no-separator") == nil)
        #expect(BuildIdentity(wireValue: "@7e1389e") == nil)
        #expect(BuildIdentity(wireValue: "branch@") == nil)
    }

    @Test("A branch difference blocks, a commit difference only warns")
    func verdicts() {
        let app = BuildIdentity(branch: "main", commit: "1111111")
        #expect(BuildIdentity.verdict(app: app, server: BuildIdentity(branch: "main", commit: "1111111")) == .match)
        #expect(BuildIdentity.verdict(app: app, server: BuildIdentity(branch: "main", commit: "2222222")) == .commitDiffers)
        #expect(BuildIdentity.verdict(app: app, server: BuildIdentity(branch: "feature", commit: "1111111")) == .branchDiffers)
        #expect(BuildIdentity.Verdict.branchDiffers.isBlocking)
        #expect(BuildIdentity.Verdict.serverUnknown.isBlocking)
        #expect(!BuildIdentity.Verdict.commitDiffers.isBlocking)
    }

    @Test("A stamped test build knows its branch and commit")
    func stampedBuild() {
        // Tests run inside the Debug simulator app, which the build phase
        // stamps; on a device or in Release there is nothing to check.
        if let app = BuildIdentity.app {
            #expect(!app.branch.isEmpty)
            #expect(app.commit.count >= 7)
        }
    }
}
