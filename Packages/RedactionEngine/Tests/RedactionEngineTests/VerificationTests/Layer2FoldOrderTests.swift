import Testing
import Foundation
@testable import RedactionEngine

// ENGINE §6 — Cross-page Layer-2 fold precedence.
// The warnable out-of-region arms (sensitive term outside regions, unmappable
// coordinates) return ahead of the Part-A fill-artifact note, so a
// multi-signal document folds to the warning. Within the note tier the order
// stays specificity (fill artifact > generic outside text); the unchecked arm
// keeps its long-standing position below the expected-state notes.

@Suite("Layer 2 fold arm order")
struct Layer2FoldOrderTests {
    private typealias Bucket = VerificationEngine.PageOCRBucket

    private func fold(
        _ outcomes: [(page: Int, bucket: Bucket)],
        mode: PipelineMode = .searchableRedaction,
        hasRegions: Bool = true
    ) -> (status: VerificationStatus, pages: [Int]?) {
        let result = VerificationEngine.foldLayer2PageOutcomes(
            outcomes, pipelineMode: mode, documentHasRegions: hasRegions)
        return (result.0, result.1)
    }

    private func message(_ status: VerificationStatus) -> String {
        switch status {
        case .fail(let m), .warn(let m), .info(let m), .attention(let m): m
        case .pass, .skipped: ""
        }
    }

    /// Walks the full arm chain: every bucket present on its own page, then
    /// the winning bucket removed one step at a time. Each step pins the
    /// arm's tier, message wording, and 0-based page references, so ANY
    /// precedence change reads red here.
    @Test("full precedence walk pins every arm's position")
    func fullPrecedenceWalk() {
        var outcomes: [(page: Int, bucket: Bucket)] = [
            (1, .sensitiveTermInRegion),
            (2, .textInRegionSecureRaster),
            (3, .textInRegionSearchable),
            (4, .sensitiveTermOutsideRegion),
            (5, .unmappable),
            (6, .fillArtifactInRegion),
            (7, .textOutsideRegionsOnly),
            (8, .unchecked),
            (9, .clean),
        ]

        var r = fold(outcomes)
        #expect(r.status.isFail, "term in region outranks every arm — got \(r.status)")
        #expect(message(r.status).contains("Sensitive text detected within a redacted region"))
        #expect(r.pages == [0])

        outcomes.removeAll { $0.bucket == .sensitiveTermInRegion }
        r = fold(outcomes)
        #expect(r.status.isFail, "in-region text on a rasterized page FAILs next — got \(r.status)")
        #expect(message(r.status).contains("Readable text detected within a redacted region"))
        #expect(r.pages == [1])

        outcomes.removeAll { $0.bucket == .textInRegionSecureRaster }
        r = fold(outcomes)
        #expect(r.status.isWarn, "in-region text on a Searchable page WARNs next — got \(r.status)")
        #expect(message(r.status).contains("OCR detected text within a redacted region"))
        #expect(r.pages == [2])

        // The two warnable out-of-region arms return ahead of the
        // fill-artifact note: a multi-signal document folds to the warning.
        outcomes.removeAll { $0.bucket == .textInRegionSearchable }
        r = fold(outcomes)
        #expect(r.status.isWarn, "term-outside WARN returns ahead of the fill note — got \(r.status)")
        #expect(message(r.status).contains("readable outside every redacted region"))
        #expect(r.pages == [3])

        outcomes.removeAll { $0.bucket == .sensitiveTermOutsideRegion }
        r = fold(outcomes)
        #expect(r.status.isWarn, "unmappable WARN returns ahead of the fill note — got \(r.status)")
        #expect(message(r.status).contains("could not be mapped to page space"))
        #expect(r.pages == [4])

        // Note tier, most specific first: fill artifact ahead of generic
        // outside text; both ahead of the unchecked arm (long-standing).
        outcomes.removeAll { $0.bucket == .unmappable }
        r = fold(outcomes)
        #expect(r.status.isInfo, "fill note wins the note tier — got \(r.status)")
        #expect(message(r.status).contains("no readable text recovered"))
        #expect(r.pages == [5])

        outcomes.removeAll { $0.bucket == .fillArtifactInRegion }
        r = fold(outcomes)
        #expect(r.status.isInfo, "generic outside-text note is next — got \(r.status)")
        #expect(message(r.status).contains("expected for Searchable Redaction mode"))
        #expect(r.pages == [6])

        outcomes.removeAll { $0.bucket == .textOutsideRegionsOnly }
        r = fold(outcomes)
        #expect(r.status.isWarn, "unchecked pages WARN once no note arm fires — got \(r.status)")
        #expect(message(r.status).contains("OCR could not be run"))
        #expect(r.pages == [7])

        outcomes.removeAll { $0.bucket == .unchecked }
        r = fold(outcomes)
        #expect(r.status == .pass, "clean pages alone fold to PASS — got \(r.status)")
        #expect(r.pages == nil)
    }

    /// The RC-6 shape with a missed-PII page beside it: proven fill artifacts
    /// on pages 2–3 plus a sensitive term readable outside every region on
    /// page 1. The fold surfaces the warning (and its page), not the note —
    /// the masthead reads off green exactly when a warnable page exists.
    @Test("multi-signal document folds to the term-outside WARN, not the fill note")
    func multiSignal_termOutsideWins() {
        let r = fold([
            (1, .sensitiveTermOutsideRegion),
            (2, .fillArtifactInRegion),
            (3, .fillArtifactInRegion),
        ])
        #expect(r.status.isWarn,
                "a warnable page must set the layer status over the fill note — got \(r.status)")
        #expect(message(r.status).contains("readable outside every redacted region"))
        #expect(!message(r.status).contains("fill artifacts"),
                "the note must not displace the warning's message")
        #expect(r.pages == [0], "page references follow the winning arm")
    }

    @Test("multi-signal document folds to the unmappable WARN over the fill note")
    func multiSignal_unmappableWins() {
        let r = fold([
            (1, .fillArtifactInRegion),
            (2, .unmappable),
        ])
        #expect(r.status.isWarn, "got \(r.status)")
        #expect(message(r.status).contains("could not be mapped to page space"))
        #expect(r.pages == [1])
    }

    /// The fill-note-vs-unchecked pairing mirrors the long-standing
    /// outside-text-vs-unchecked steady state, pinned here side by side.
    @Test("note arms keep their position above the unchecked arm")
    func noteArms_aboveUnchecked() {
        let fill = fold([(1, .fillArtifactInRegion), (2, .unchecked)])
        #expect(fill.status.isInfo, "got \(fill.status)")
        #expect(message(fill.status).contains("no readable text recovered"))
        #expect(fill.pages == [0])

        let outside = fold([(1, .textOutsideRegionsOnly), (2, .unchecked)])
        #expect(outside.status.isInfo, "got \(outside.status)")
        #expect(message(outside.status).contains("expected for Searchable Redaction mode"))
        #expect(outside.pages == [0])
    }

    /// The verdict is independent of outcome order (the task group completes
    /// pages in any order) and page lists stay sorted in messages.
    @Test("verdict independent of outcome order; page lists sorted")
    func orderIndependence() {
        let r = fold([
            (3, .fillArtifactInRegion),
            (1, .fillArtifactInRegion),
            (2, .fillArtifactInRegion),
        ])
        #expect(r.status.isInfo, "got \(r.status)")
        #expect(message(r.status).contains("3 pages: 1, 2, 3"))
        #expect(r.pages == [0, 1, 2])
    }

    /// Secure-raster mode's outside-text arm: INFO when the document had
    /// regions, PASS when it had none (the raster's own content).
    @Test("secure-raster outside-text arm keys on documentHasRegions")
    func secureRasterOutsideText() {
        let noted = fold([(1, .textOutsideRegionsOnly)],
                         mode: .secureRasterization, hasRegions: true)
        #expect(noted.status.isInfo, "got \(noted.status)")
        #expect(message(noted.status).contains("Unredacted page content remains readable"))

        let clean = fold([(1, .textOutsideRegionsOnly)],
                         mode: .secureRasterization, hasRegions: false)
        #expect(clean.status == .pass, "got \(clean.status)")
        #expect(clean.pages == nil)
    }
}
