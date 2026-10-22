import Testing
@testable import ResectaApp
@testable import RedactionEngine

// VoiceOver says what the screen shows: every spoken status label opens
// with its status's visible title, then one sentence of advice.

@Suite("Verification status: the spoken label follows the title")
struct VerificationSpokenLabelTests {

    @Test("Every spoken label opens with its status's title, as the screen shows it", arguments: [
        VerificationStatus.pass, .warn("w"), .attention("a"), .fail("f"), .skipped,
    ])
    func spokenLabelOpensWithTheTitle(status: VerificationStatus) {
        let title = status.title.replacingOccurrences(of: "\u{00A0}", with: " ").lowercased()
        #expect(status.accessibilityLabel.lowercased().hasPrefix(title + "."), "\(status.accessibilityLabel) vs \(title)")
    }
}
