import Testing
import Foundation
@testable import ResectaApp
@testable import RedactionEngine

// The VoiceOver announcement at the end of a run speaks the status only:
// the masthead's spoken label quotes the review terms on a needs-review
// result, and an announcement would read document text aloud.

@Suite("Verification completion announcement")
@MainActor
struct VerificationAnnouncementTests {

    @Test("The runner announces the completion line, never the masthead label (source pin)")
    func announcesTheStatusOnly() throws {
        let runner = URL(fileURLWithPath: "\(#filePath)")
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/ResectaApp/State/PipelineRunner.swift")
        let source = try String(contentsOf: runner, encoding: .utf8)
        #expect(source.contains(".announce(VerificationResultsView.completionAnnouncement(report: report))"))
        #expect(!source.contains("overallStatus.accessibilityLabel"),
                "the run's end speaks the masthead's title, never a separate status label")
        #expect(!source.contains("mastheadAccessibilityLabel"), "the masthead label quotes review terms")
    }

    @Test("A PASS with rows that had nothing to check speaks the header's counts, never \"without issues\"; every report opens with its title")
    func passWithNothingToCheckSpeaksTheCounts() {
        let rasterized = VerificationDebugFixtures.searchableAllRasterized
        let line = VerificationResultsView.completionAnnouncement(report: rasterized)
        #expect(line == "Verification complete. Checks Passed. 9 of 12 checks passed. 3\u{00A0}had nothing to check.")
        #expect(!line.contains("without issues"))
        #expect(!VerificationResultsView.completionAnnouncement(report: VerificationDebugFixtures.searchableAllPass)
                .contains("without issues"))
        // Every verdict speaks the masthead's title, and no line quotes a review term.
        for (name, report) in VerificationDebugFixtures.all {
            let spoken = VerificationResultsView.completionAnnouncement(report: report)
            #expect(spoken.hasPrefix("Verification complete. "), "\(name)")
            for term in VerificationResultsView.reviewTermTexts(report: report) {
                #expect(!spoken.contains(term), "\(name) speaks \(term)")
            }
            #expect(spoken.hasPrefix("Verification complete. \(VerificationResultsView.mastheadTitle(report: report))."),
                    "\(name)")
        }
    }
}
