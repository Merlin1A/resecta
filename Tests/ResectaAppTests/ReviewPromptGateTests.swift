import Testing
import Foundation
@testable import ResectaApp
@testable import RedactionEngine

// The App Store rating prompt asks once per app version, after the first
// completed share of a document whose checks passed — never after a share
// whose checks reported issues, did not run in full or were skipped.

@Suite("Rating prompt gate")
struct ReviewPromptGateTests {

    private func scratchDefaults(_ function: String = #function) -> UserDefaults {
        let name = "app.resecta.tests.ReviewPromptGate.\(function).\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: name)!
        suite.removePersistentDomain(forName: name)
        return suite
    }

    @Test("The first passed share of a version asks; the next share of that version does not")
    func asksOncePerVersion() {
        let defaults = scratchDefaults()
        let gate = ReviewPromptGate(defaults: defaults, appVersion: "1.3.0")
        #expect(gate.shouldAsk(afterSharing: .pass))
        #expect(!gate.shouldAsk(afterSharing: .pass), "the version already asked")
        #expect(defaults.string(forKey: ReviewPromptGate.askedVersionKey) == "1.3.0")
    }

    @Test("A new version asks again after its first passed share")
    func newVersionAsksAgain() {
        let defaults = scratchDefaults()
        #expect(ReviewPromptGate(defaults: defaults, appVersion: "1.3.0").shouldAsk(afterSharing: .pass))
        #expect(ReviewPromptGate(defaults: defaults, appVersion: "1.3.1").shouldAsk(afterSharing: .pass))
    }

    @Test("Checks that passed with notes count as passed")
    func infoCountsAsPassed() {
        let gate = ReviewPromptGate(defaults: scratchDefaults(), appVersion: "1.3.0")
        #expect(gate.shouldAsk(afterSharing: .info("note")))
    }

    @Test("A share whose checks did not pass never asks and records nothing")
    func nonPassingSharesNeverAsk() {
        let defaults = scratchDefaults()
        let gate = ReviewPromptGate(defaults: defaults, appVersion: "1.3.0")
        for status: VerificationStatus in [.warn("w"), .attention("a"), .fail("f"), .skipped] {
            #expect(!gate.shouldAsk(afterSharing: status), "\(status) must not ask")
        }
        #expect(defaults.string(forKey: ReviewPromptGate.askedVersionKey) == nil,
                "nothing recorded, so the first passed share still asks")
        #expect(gate.shouldAsk(afterSharing: .pass))
    }
}
