import Testing
import Foundation
@testable import RedactionEngine

// ENGINE §6 — Cross-page Layer-2 fold precedence.
// The warnable out-of-region arm (unmappable coordinates) returns ahead of
// the Part-A fill-artifact note, so a multi-signal document folds to the
// warning. Within the note tier the order stays specificity (fill artifact >
// generic outside text); the unchecked arm keeps its long-standing position
// below the expected-state notes. The dedicated sensitive-term-outside WARN
// arm is de-escalated (D-86 / RW-F-002(b)): `pageBucket(for:effectiveMode:)`
// folds that finding to the generic outside bucket on both page modes, so the
// secure-raster informational is the record surface for it (mapping matrix +
// record string pinned below).

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

        // The warnable out-of-region arm returns ahead of the fill-artifact
        // note: a multi-signal document folds to the warning. (The dedicated
        // sensitive-term-outside arm that once sat here is de-escalated —
        // D-86 / RW-F-002(b) — see the mapping-matrix pin below.)
        outcomes.removeAll { $0.bucket == .textInRegionSearchable }
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

    /// D-86 / RW-F-002(b): the A18 record shape, byte-exact. Term-outside
    /// pages reach the fold already de-escalated into the generic outside
    /// bucket (pages 2–3 here beside page 1's ordinary readable content), so
    /// a secure-raster document with regions folds to the record
    /// informational — full-string equality so any wording or page-list
    /// drift reads red here.
    @Test("de-escalated term-outside pages fold to the secure-raster record informational, byte-exact")
    func termOutside_deescalatesToRecordInformational() {
        let r = fold([
            (1, .textOutsideRegionsOnly),
            (2, .textOutsideRegionsOnly),
            (3, .textOutsideRegionsOnly),
        ], mode: .secureRasterization, hasRegions: true)
        #expect(r.status.isInfo, "got \(r.status)")
        #expect(message(r.status) ==
            "Unredacted page content remains readable on 3 pages: 1, 2, 3 — expected for this mode.",
            "the record string must render byte-exact — got \(message(r.status))")
        #expect(r.pages == [0, 1, 2])
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

    /// D-86 / RW-F-002(b): the finding→bucket mapping matrix. The
    /// de-escalation lives in this seam: `.sensitiveTermOutsideRegions` folds
    /// to the generic outside bucket on BOTH page modes, while in-region
    /// findings keep their mode-keyed buckets. Red→green pinned with a
    /// stashed-fix negative control at RW-FIX-1 (the pre-fix engine returned
    /// the dedicated WARN on the secure-raster leg).
    @Test("finding→bucket mapping: term-outside de-escalates on both modes; in-region stays mode-keyed")
    func pageBucketMapping() {
        typealias Finding = VerificationEngine.PageOCRFinding
        func bucket(_ f: Finding, _ m: PipelineMode) -> Bucket {
            VerificationEngine.pageBucket(for: f, effectiveMode: m)
        }
        for mode in [PipelineMode.secureRasterization, .searchableRedaction] {
            #expect(bucket(.sensitiveTermInRegion, mode) == .sensitiveTermInRegion)
            #expect(bucket(.fillArtifactInRegion, mode) == .fillArtifactInRegion)
            #expect(bucket(.sensitiveTermOutsideRegions, mode) == .textOutsideRegionsOnly,
                    "D-86: the term-outside signal folds generic on \(mode)")
            #expect(bucket(.textOutsideRegionsOnly, mode) == .textOutsideRegionsOnly)
            #expect(bucket(Finding.none, mode) == .clean)
        }
        #expect(bucket(.textInRegion, .secureRasterization) == .textInRegionSecureRaster)
        #expect(bucket(.textInRegion, .searchableRedaction) == .textInRegionSearchable)
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
