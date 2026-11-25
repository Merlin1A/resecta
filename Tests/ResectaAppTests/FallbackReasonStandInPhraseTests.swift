import Foundation
import Testing
@testable import ResectaApp
@testable import RedactionEngine

// A new per-page reason ships with its own words only. Until they arrive, a
// new reason shows an existing approved phrase as a stand-in, and the list
// below names each reason still showing one. Each row is checked against the
// reason's display phrase, so a row outlives its stand-in only as a red test.
// At the candidate (`RESECTA_CANDIDATE_GATE=1` in the test's environment) the
// list must be empty: a build that still shows a stand-in is refused. No
// reason shows a stand-in today, so the list is empty.

@Suite("Fallback reasons: stand-in phrases still in use")
struct FallbackReasonStandInPhraseTests {

    struct StandIn: Sendable, CustomTestStringConvertible {
        let reason: TextLayerDetector.FallbackReason
        let phrase: String
        var testDescription: String { phrase }
    }

    // nonisolated: read by the @Test(arguments:) macro expansion outside the
    // target's MainActor default isolation; an immutable constant is safe.
    nonisolated static let standIns: [StandIn] = []

    /// The refusal at the candidate: the phrases still shown as stand-ins
    /// when `RESECTA_CANDIDATE_GATE=1` is in `environment` and the list is not
    /// empty; nil otherwise.
    static func refusal(environment: [String: String], standIns: [StandIn]) -> [String]? {
        guard environment["RESECTA_CANDIDATE_GATE"] == "1", !standIns.isEmpty else { return nil }
        return standIns.map(\.phrase)
    }

    @Test("The list holds no stand-in")
    func rowCount() {
        #expect(Self.standIns.isEmpty)
    }

    @Test("The refusal fires at the candidate while a stand-in stands, and only then")
    func refusalFires() {
        let row = StandIn(reason: .invisibleText, phrase: "a stand-in phrase")
        #expect(Self.refusal(environment: ["RESECTA_CANDIDATE_GATE": "1"], standIns: [row]) == ["a stand-in phrase"])
        #expect(Self.refusal(environment: [:], standIns: [row]) == nil)
        #expect(Self.refusal(environment: ["RESECTA_CANDIDATE_GATE": "0"], standIns: [row]) == nil)
        #expect(Self.refusal(environment: ["RESECTA_CANDIDATE": "1"], standIns: [row]) == nil)
        #expect(Self.refusal(environment: ["RESECTA_CANDIDATE_GATE": "1"], standIns: []) == nil)
    }

    @Test("Each listed reason shows its listed stand-in")
    func listedPhraseShown() {
        for row in Self.standIns {
            #expect(row.reason.shortReasonText == row.phrase, "\(row.reason)")
        }
    }

    @Test("No two listed reasons share a row")
    func reasonsDistinct() {
        #expect(Set(Self.standIns.map(\.reason)).count == Self.standIns.count)
    }

    @Test("At the candidate no reason shows a stand-in")
    func noneAtCandidate() {
        let refused = Self.refusal(environment: ProcessInfo.processInfo.environment, standIns: Self.standIns)
        #expect(refused == nil, "stand-ins still shown: \(refused ?? [])")
    }
}
