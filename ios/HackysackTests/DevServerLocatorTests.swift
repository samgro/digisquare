//
//  DevServerLocatorTests.swift
//  HackysackTests
//

import Testing
@testable import Hackysack

@Suite("Dev server locator")
struct DevServerLocatorTests {
    private let app = BuildIdentity(branch: "claude/places", commit: "7e1389e")

    @Test("Picks the server on this build's branch over a lower port")
    func prefersMatchingBranch() {
        let probes = [
            DevServerProbe(port: 3000, branch: "claude/other"),
            DevServerProbe(port: 3001, branch: nil),
            DevServerProbe(port: 3002, branch: "claude/places"),
        ]
        #expect(DevServerLocator.choose(app: app, among: probes)?.port == 3002)
    }

    @Test("Falls back to the first server that answered, for the gate to explain")
    func fallsBackToFirstResponder() {
        let probes = [DevServerProbe(port: 3001, branch: "claude/other"), DevServerProbe(port: 3003, branch: nil)]
        #expect(DevServerLocator.choose(app: app, among: probes)?.port == 3001)
    }

    @Test("Keeps the default when nothing answered")
    func nothingAnswered() {
        #expect(DevServerLocator.choose(app: app, among: []) == nil)
    }
}
