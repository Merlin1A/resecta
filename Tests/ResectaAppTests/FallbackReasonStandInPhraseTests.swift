import Foundation
import Testing
@testable import ResectaApp
@testable import RedactionEngine

// A new per-page reason ships with its own words only. Until they arrive, a
// new reason shows an existing approved phrase as a stand-in, and the list
// below names each reason still showing one. Each row is checked against the
// reason's display phrase, so a row outlives its stand-in only as a red test.
// At the candidate (`RESECTA_CANDIDATE=1`, or `TEST_RUNNER_RESECTA_CANDIDATE=1`
// under xcodebuild) the list must be empty: a build that still shows a
// stand-in is refused.

@Suite("Fallback reasons: stand-in phrases still in use")
struct FallbackReasonStandInPhraseTests {

    struct StandIn: Sendable, CustomTestStringConvertible {
        let reason: TextLayerDetector.FallbackReason
        let phrase: String
        var testDescription: String { phrase }
    }

    // nonisolated: read by the @Test(arguments:) macro expansion outside the
    // target's MainActor default isolation; an immutable constant is safe.
    nonisolated static let standIns: [StandIn] = [
        StandIn(reason: .invisibleText, phrase: "invisible text on the page"),
    ]

    static var atCandidate: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["RESECTA_CANDIDATE"] == "1" || env["TEST_RUNNER_RESECTA_CANDIDATE"] == "1"
    }

    @Test("The list holds one stand-in")
    func rowCount() {
        #expect(Self.standIns.count == 1)
    }

    @Test("Each listed reason shows its listed stand-in", arguments: standIns)
    func listedPhraseShown(_ row: StandIn) {
        #expect(row.reason.shortReasonText == row.phrase)
    }

    @Test("No two listed reasons share a row")
    func reasonsDistinct() {
        #expect(Set(Self.standIns.map(\.reason)).count == Self.standIns.count)
    }

    @Test("At the candidate no reason shows a stand-in")
    func noneAtCandidate() {
        #expect(!Self.atCandidate || Self.standIns.isEmpty,
                "stand-ins still shown: \(Self.standIns.map(\.phrase))")
    }
}
