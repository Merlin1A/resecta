import Testing
@testable import ResectaApp
import RedactionEngine

// `CouldNotVerifyWarn.matches` — the app-side predicate behind the
// incomplete-WARN share confirm. The engine classifies each WARN at the
// site that composes it (`LayerResult.couldNotVerify`, pinned by the engine
// package's own table suite and source census); this suite pins that the
// app keys on that flag and never on the message text. The two message
// tables document the family the confirm now covers and the routine notes
// it leaves alone; they are the engine's own sentences, with counts filled
// in where the engine composes them.
@Suite("Could-not-verify WARN predicate")
struct CouldNotVerifyWarnTests {

    private func layer(_ status: VerificationStatus, message: String,
                       couldNotVerify: Bool) -> LayerResult {
        LayerResult(name: "Layer", symbolName: "checkmark", status: status,
                    shortDescription: message, detailDescription: "",
                    pageReferences: nil, durationSeconds: 0,
                    couldNotVerify: couldNotVerify)
    }

    /// The engine's could-not-verify sentences: a check that did not fully
    /// run on the output — pages it could not read or open, OCR it could not
    /// run or map, terms it could not search, positions it could not
    /// measure, per-page data it lacked, the Search Re-check's unchecked
    /// pages.
    nonisolated static let couldNotVerifyMessages: [String] = [
        // Text Extraction
        "Could not verify /AcroForm absence",
        "2 pages could not be read for this check: 1, 2",
        // OCR Check
        "OCR could not be run on 2 pages",
        "OCR coordinates could not be mapped to page space on page 1 — text could not be confirmed inside or outside a redacted region",
        // Binary String Search / Operator Re-Extraction
        "All sensitive terms shorter than 3 characters",
        "Sensitive term search exceeded size limit — results may be incomplete",
        "Operator-semantic term search exceeded size limit — results may be incomplete",
        "Could not read output PDF for binary search",
        "Operator scanner unavailable for page 1",
        "Operator scanner could not traverse page 1",
        // Structure / Metadata
        "Could not inspect document structure",
        "Could not inspect metadata",
        // Spatial Verification / Font Verification
        "3 characters had no measurable position and were not position-checked",
        "Could not inspect page fonts on page 2",
        "Page 2 has no page-level /Resources — font verification skipped",
        // Coverage arm of the per-page checks
        "Per-page mode data covered 1 of 2 pages; 1 page not checked",
        // Character Count / Character Lineage
        "Cross-checked 1 of 2 pages — remaining pages lacked rasterization data",
        // Search Re-check
        "1 search re-run; 1 page could not be checked: 2",
    ]

    /// The engine's routine WARN notes: a check that ran and reported what
    /// it saw. Never in the family.
    nonisolated static let routineWarnMessages: [String] = [
        "Structural findings: URI",  // LegalPhrases:safe (the engine message)
        "Metadata present: Trapped",
        "Auto-injected metadata present: XMP metadata",
        "OCR detected text within a redacted region on page 1",
        "A character touches the edge of a redacted area on page 1.",
        "Producer or timestamp fields were not rewritten to the fixed values",
        "Character count excess on page 1: 60 characters against a digest of 0",
        "Verification produced warnings",
        "Some verification checks were skipped — results may be incomplete",
    ]

    @Test("every engine could-not-verify sentence matches when the engine flags it",
          arguments: couldNotVerifyMessages)
    func familyMatches(message: String) {
        #expect(CouldNotVerifyWarn.matches(
            layer(.warn(message), message: message, couldNotVerify: true)),
            "\(message)")
    }

    @Test("routine WARN notes never match", arguments: routineWarnMessages)
    func routineNoteDoesNotMatch(message: String) {
        #expect(!CouldNotVerifyWarn.matches(
            layer(.warn(message), message: message, couldNotVerify: false)),
            "\(message)")
    }

    @Test("the message text is never consulted: a could-not-verify sentence without the flag does not match",
          arguments: couldNotVerifyMessages)
    func textAloneDoesNotMatch(message: String) {
        #expect(!CouldNotVerifyWarn.matches(
            layer(.warn(message), message: message, couldNotVerify: false)),
            "\(message)")
    }

    @Test("PASS / INFO / ATTENTION / FAIL / SKIPPED never match, even with the flag set")
    func nonWarnStatusesNeverMatch() {
        let statuses: [VerificationStatus] =
            [.pass, .info("i"), .attention("a"), .fail("f"), .skipped]
        for status in statuses {
            #expect(!CouldNotVerifyWarn.matches(
                layer(status, message: "Could not inspect metadata", couldNotVerify: true)),
                "\(status)")
        }
    }
}
