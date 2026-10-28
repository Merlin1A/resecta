import Testing
import Foundation
@testable import ResectaApp
@testable import RedactionEngine

// Three results sentences that said something the screen did not: the
// end-of-run VoiceOver line spoke a different title from the masthead's;
// with Verify Before Export off, the advice sent the reader to a Redact
// that skips the checks again; and a match the user left unapplied on
// purpose was told to be redacted on every run.

@Suite("Masthead sentences say what the screen shows")
@MainActor
struct MastheadSentenceTests {

    private typealias Results = VerificationResultsView
    private typealias Fixtures = VerificationDebugFixtures

    // MARK: - The end-of-run announcement

    @Test("Every report's announcement opens with the masthead's own title")
    func announcementSpeaksTheMastheadTitle() {
        for (name, report) in Fixtures.all {
            let spoken = Results.completionAnnouncement(report: report)
            #expect(spoken.hasPrefix("Verification complete. \(Results.mastheadTitle(report: report))."), "\(name): \(spoken)")
            for term in Results.reviewTermTexts(report: report) {
                #expect(!spoken.contains(term), "\(name) speaks \(term)")
            }
        }
    }

    @Test("Some Checks Incomplete is spoken as Some Checks Incomplete, never as Completed with warnings")
    func incompleteIsSpokenAsShown() throws {
        let incomplete = Fixtures.all.filter { Results.mastheadTitle(report: $0.value) == "Some Checks Incomplete" }
        try #require(!incomplete.isEmpty)
        for (name, report) in incomplete {
            let spoken = Results.completionAnnouncement(report: report)
            #expect(spoken.contains("Some Checks Incomplete"), "\(name)")
            #expect(!spoken.contains("Completed with warnings"), "\(name)")
        }
    }

    // MARK: - Verify Before Export off

    @Test("With Verify Before Export off, the skipped advice names the setting and never a Redact that skips again")
    func verifyOffAdviceNamesTheSetting() {
        let sentence = Results.skippedSubtitle(reason: .autoVerifyOff, mode: .searchableOrUnknown)
        #expect(sentence.contains("Verify Before Export"))
        #expect(!sentence.contains("run Redact for all checks"))
        #expect(sentence.count <= Results.mastheadSentenceLimit)
    }

    @Test("A WARN with skipped checks names the setting the full run needs")
    func skippedWarnNamesTheSetting() {
        let skipped = LayerResult(name: "Character Count", symbolName: "number", status: .skipped,
                                  shortDescription: "", detailDescription: "", pageReferences: nil,
                                  durationSeconds: 0, layer: .characterCount)
        let report = VerificationReport(layers: [skipped], overallStatus: .warn("w"), durationSeconds: 0)
        let sentence = Results.mastheadSubtitle(report: report) ?? ""
        #expect(sentence.contains("Verify Before Export"), "\(sentence)")
        #expect(sentence.count <= Results.mastheadSentenceLimit)
    }

    // MARK: - A match left unapplied on purpose

    private static func keptReport(found: Int, applied: Int, remaining: Int) -> VerificationReport {
        let ocrRow = LayerResult(
            name: "OCR Check", symbolName: "doc.text.magnifyingglass",
            status: .attention("Text matching your redactions is still readable on page 2 (1 instance)"),
            shortDescription: "", detailDescription: "", pageReferences: [1], durationSeconds: 0,
            reviewTermTexts: ["Amount"], layer: .ocrCheck)
        let recheck = LayerResult(
            name: "Search Re-check", symbolName: "magnifyingglass", status: .pass,
            shortDescription: "", detailDescription: "", pageReferences: nil, durationSeconds: 0,
            layer: .searchRecheck,
            queryLines: [SearchRecheckQueryLine(label: "\u{201C}Amount\u{201D}", foundCount: found, foundHitCap: false,
                                                appliedCount: applied, remainingCount: remaining, route: .textLayer)])
        return VerificationReport(layers: [ocrRow, recheck],
                                  overallStatus: .attention("x"), durationSeconds: 0)
    }

    @Test("A term whose remaining match the user left unapplied is named as left, not as one to redact")
    func keptOccurrenceIsNamedAsLeft() {
        let sentence = Results.attentionSentence(report: Self.keptReport(found: 644, applied: 643, remaining: 1))
        #expect(!sentence.text.contains("to redact \u{201C}Amount\u{201D}"))
        #expect(sentence.text == "You left 1 match of \u{201C}Amount\u{201D} unapplied; review it before you share.")
        #expect(sentence.quotesTerms)
        #expect(sentence.text.count <= Results.mastheadSentenceLimit)
    }

    @Test("A remaining match beyond what the user left unapplied keeps the redact sentence")
    func unaccountedMatchKeepsTheRedactSentence() {
        let sentence = Results.attentionSentence(report: Self.keptReport(found: 644, applied: 644, remaining: 1))
        #expect(sentence.text.contains("to redact \u{201C}Amount\u{201D}"))
    }
}
