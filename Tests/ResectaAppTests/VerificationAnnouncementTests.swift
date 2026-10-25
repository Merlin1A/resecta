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
        #expect(!source.contains("Verification complete. \\(report.overallStatus.accessibilityLabel)"),
                "a bare PASS label says \"without issues\" over rows that had nothing to check")
        #expect(!source.contains("mastheadAccessibilityLabel"), "the masthead label quotes review terms")
    }

    @Test("A PASS with rows that had nothing to check speaks the header's counts, never \"without issues\"; a clean PASS keeps the label")
    func passWithNothingToCheckSpeaksTheCounts() {
        let rasterized = VerificationDebugFixtures.searchableAllRasterized
        let line = VerificationResultsView.completionAnnouncement(report: rasterized)
        #expect(line == "Verification complete. Checks Passed. 9 of 12 checks passed. 3\u{00A0}had nothing to check.")
        #expect(!line.contains("without issues"))
        #expect(VerificationResultsView.completionAnnouncement(report: VerificationDebugFixtures.searchableAllPass)
                == "Verification complete. \(VerificationStatus.pass.accessibilityLabel)")
        // Every other verdict speaks its label, and no line quotes a review term.
        for (name, report) in VerificationDebugFixtures.all {
            let spoken = VerificationResultsView.completionAnnouncement(report: report)
            #expect(spoken.hasPrefix("Verification complete. "), "\(name)")
            for term in VerificationResultsView.reviewTermTexts(report: report) {
                #expect(!spoken.contains(term), "\(name) speaks \(term)")
            }
            if case .pass = report.overallStatus {} else {
                #expect(spoken == "Verification complete. \(report.overallStatus.accessibilityLabel)", "\(name)")
            }
        }
    }

    @Test("A status label is a fixed sentence: it never carries the status's own message text")
    func statusLabelsAreFixedSentences() {
        let marker = "SENTINEL-4471"
        for status in [VerificationStatus.warn(marker), .attention(marker), .fail(marker), .info(marker)] {
            #expect(!status.accessibilityLabel.contains(marker), "\(status)")
            #expect(!status.accessibilityLabel.isEmpty)
        }
        #expect(!VerificationStatus.pass.accessibilityLabel.isEmpty)
    }
}
