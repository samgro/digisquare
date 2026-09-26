//
//  SwarmImportTests.swift
//  HackysackTests
//

import Foundation
import Testing
@testable import Hackysack

@Suite("Swarm import progress")
struct SwarmImportTests {
    private func swarmImport(
        status: SwarmImport.Status = .running,
        phase: SwarmImport.Phase = .checkins,
        checkinsImported: Int = 0,
        checkinsExpected: Int? = nil,
        photosTotal: Int = 0,
        photosCopied: Int = 0,
        error: String? = nil
    ) -> SwarmImport {
        SwarmImport(
            id: "import",
            status: status,
            phase: phase,
            checkinsImported: checkinsImported,
            checkinsExpected: checkinsExpected,
            photosTotal: photosTotal,
            photosCopied: photosCopied,
            error: error,
            startedAt: Date(),
            finishedAt: status == .running ? nil : Date()
        )
    }

    @Test func progressIsUnknownUntilTheServerHasAsked() {
        let starting = swarmImport(checkinsImported: 12)
        #expect(starting.progressFraction == nil)
        #expect(starting.progressDetail == "12 checkins so far")
    }

    @Test func checkinsProgressIsMeasuredAgainstTheExpectedCount() throws {
        let halfway = swarmImport(checkinsImported: 1_906, checkinsExpected: 3_812)
        #expect(try #require(halfway.progressFraction).isApproximatelyEqual(to: 0.5))
        #expect(halfway.progressTitle == "Importing your Swarm checkins")
        #expect(halfway.progressDetail == "1,906 of 3,812 checkins")
    }

    @Test func aResyncThatReadsMoreThanExpectedNeverOverfills() throws {
        let over = swarmImport(checkinsImported: 40, checkinsExpected: 10)
        #expect(try #require(over.progressFraction) == 1)
    }

    @Test func photosProgressIsMeasuredAgainstTheirTotal() throws {
        let copying = swarmImport(phase: .photos, checkinsImported: 3_812, checkinsExpected: 3_812, photosTotal: 980, photosCopied: 245)
        #expect(try #require(copying.progressFraction).isApproximatelyEqual(to: 0.25))
        #expect(copying.progressTitle == "Copying your Swarm photos")
        #expect(copying.progressDetail.hasPrefix("245 of 980 photos"))
    }

    @Test func aFinishedImportIsFullWhateverItsCounts() {
        let finished = swarmImport(status: .completed, phase: .photos, checkinsImported: 1)
        #expect(finished.progressFraction == 1)
        #expect(finished.progressDetail == "1 checkin added")
    }

    @Test func aFailedImportShowsTheServersExplanation() {
        let failed = swarmImport(status: .failed, checkinsImported: 500, checkinsExpected: 3_812, error: "Foursquare had a problem.")
        #expect(failed.progressTitle == "Swarm import stopped")
        #expect(failed.progressDetail == "Foursquare had a problem.")
    }
}

private extension Double {
    func isApproximatelyEqual(to other: Double) -> Bool {
        abs(self - other) < 0.0001
    }
}
