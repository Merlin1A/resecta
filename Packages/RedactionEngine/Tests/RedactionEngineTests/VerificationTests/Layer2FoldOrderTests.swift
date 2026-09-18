import Testing
import Foundation
@testable import RedactionEngine

// Cross-page Layer-2 fold precedence.
// A redacted term still readable OUTSIDE every region folds to ATTENTION on
// both page modes, above the WARN tier (the report aggregate ranks attention
// above warn) and with the matched term texts threaded for the results row.
// The warnable out-of-region arm (unmappable coordinates) returns ahead of
// the Part-A fill-artifact note, so a multi-signal document folds to the
// warning. Within the note tier the order stays specificity (fill artifact >
// generic outside text); the unchecked arm keeps its long-standing position
// below the expected-state notes. The generic outside-text informational is
// the record surface for the page's own un-redacted content only (mapping
// matrix + record string pinned below).

@Suite("Layer 2 fold arm order")
struct Layer2FoldOrderTests {
    private typealias Bucket = VerificationEngine.PageOCRBucket

    private func fold(
        _ outcomes: [(page: Int, bucket: Bucket)],
        mode: PipelineMode = .searchableRedaction,
        hasRegions: Bool = true,
        terms: [Int: [String]] = [:]
    ) -> (status: VerificationStatus, pages: [Int]?, terms: [String]?, couldNotVerify: Bool) {
        let result = VerificationEngine.foldLayer2PageOutcomes(
            outcomes, pipelineMode: mode, documentHasRegions: hasRegions,
            reviewTermsByPage: terms)
        return (result.0, result.1, result.2, result.3)
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
            (4, .sensitiveTermOutsideRegions),
            (5, .unmappable),
            (6, .fillArtifactInRegion),
            (7, .textOutsideRegionsOnly),
            (8, .unchecked),
            (9, .clean),
        ]
        let terms = [4: ["CONFIDENTIAL"]]

        var r = fold(outcomes, terms: terms)
        #expect(r.status.isFail, "term in region outranks every arm — got \(r.status)")
        #expect(message(r.status).contains("Sensitive text detected within a redacted region"))
        #expect(r.pages == [0])
        #expect(r.terms == nil, "only the attention arm carries term texts")

        outcomes.removeAll { $0.bucket == .sensitiveTermInRegion }
        r = fold(outcomes, terms: terms)
        #expect(r.status.isFail, "in-region text on a rasterized page FAILs next — got \(r.status)")
        #expect(message(r.status).contains("Readable text detected within a redacted region"))
        #expect(r.pages == [1])

        outcomes.removeAll { $0.bucket == .textInRegionSecureRaster }
        r = fold(outcomes, terms: terms)
        #expect(r.status.isWarn, "in-region text on a Searchable page WARNs next — got \(r.status)")
        #expect(message(r.status).contains("OCR detected text within a redacted region"))
        #expect(r.pages == [2])

        // A redacted term readable outside every region: ATTENTION, above the
        // WARN tier (the aggregate ranks attention above warn), with the term
        // texts threaded and the message content-free.
        outcomes.removeAll { $0.bucket == .textInRegionSearchable }
        r = fold(outcomes, terms: terms)
        #expect(r.status.isAttention, "term-outside ATTENTION returns ahead of the WARN tier — got \(r.status)")
        #expect(message(r.status).contains("still readable"))
        #expect(!message(r.status).contains("CONFIDENTIAL"), "the message never echoes a term")
        #expect(r.pages == [3])
        #expect(r.terms == ["CONFIDENTIAL"])
        #expect(!r.couldNotVerify, "a leak result never carries the could-not-verify flag")

        // The warnable out-of-region arm returns ahead of the fill-artifact
        // note: a multi-signal document folds to the warning.
        outcomes.removeAll { $0.bucket == .sensitiveTermOutsideRegions }
        r = fold(outcomes, terms: terms)
        #expect(r.status.isWarn, "unmappable WARN returns ahead of the fill note — got \(r.status)")
        #expect(message(r.status).contains("could not be mapped to page space"))
        #expect(r.couldNotVerify, "unmappable coordinates: the check did not fully run")
        #expect(r.pages == [4])
        #expect(r.terms == nil)

        // Note tier, most specific first: fill artifact ahead of generic
        // outside text; both ahead of the unchecked arm (long-standing).
        outcomes.removeAll { $0.bucket == .unmappable }
        r = fold(outcomes, terms: terms)
        #expect(r.status.isInfo, "fill note wins the note tier — got \(r.status)")
        #expect(message(r.status).contains("no readable text recovered"))
        #expect(r.pages == [5])

        outcomes.removeAll { $0.bucket == .fillArtifactInRegion }
        r = fold(outcomes, terms: terms)
        #expect(r.status.isInfo, "generic outside-text note is next — got \(r.status)")
        #expect(message(r.status).contains("expected for Searchable Redaction mode"))
        #expect(r.pages == [6])

        outcomes.removeAll { $0.bucket == .textOutsideRegionsOnly }
        r = fold(outcomes, terms: terms)
        #expect(r.status.isWarn, "unchecked pages WARN once no note arm fires — got \(r.status)")
        #expect(message(r.status).contains("OCR could not be run"))
        #expect(r.couldNotVerify, "unchecked pages: the check did not fully run")
        #expect(r.pages == [7])

        outcomes.removeAll { $0.bucket == .unchecked }
        r = fold(outcomes, terms: terms)
        #expect(r.status == .pass, "clean pages alone fold to PASS — got \(r.status)")
        #expect(r.pages == nil)
        #expect(r.terms == nil)
    }

    /// The generic record string is byte-exact: pages carrying only the
    /// page's own un-redacted content (no term match) on a secure-raster
    /// document with regions fold to the record informational — full-string
    /// equality so any wording or page-list drift reads red here.
    @Test("outside-text-only pages fold to the secure-raster record informational, byte-exact")
    func textOutsideOnly_recordInformationalByteExact() {
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
        #expect(r.terms == nil)
    }

    /// The term-outside arm: ATTENTION on BOTH page modes with a byte-exact,
    /// content-free message; it outranks the unmappable WARN on a
    /// multi-signal document (single-outcome fold, as a FAIL masks every
    /// lower arm); the review terms are the union of the per-page texts in
    /// page order, deduplicated; the page list is sorted and 0-based.
    @Test("term-outside pages fold to ATTENTION with review terms; attention outranks the unmappable WARN; review terms deduped in page order")
    func termOutside_foldsToAttentionWithReviewTerms() {
        for mode in [PipelineMode.secureRasterization, .searchableRedaction] {
            let r = fold([
                (3, .sensitiveTermOutsideRegions),
                (2, .unmappable),
                (1, .sensitiveTermOutsideRegions),
                (4, .textOutsideRegionsOnly),
            ], mode: mode, hasRegions: true,
               terms: [3: ["CONFIDENTIAL", "INTERNAL"], 1: ["INTERNAL"]])
            #expect(r.status.isAttention, "\(mode): got \(r.status)")
            #expect(message(r.status) ==
                "Text matching your redactions is still readable on 2 pages: 1, 3 — read by OCR outside every redacted region",
                "\(mode): the attention message must render byte-exact — got \(message(r.status))")
            #expect(!message(r.status).contains("CONFIDENTIAL") && !message(r.status).contains("INTERNAL"),
                    "the message never echoes a term")
            #expect(r.pages == [0, 2], "\(mode): 0-based, sorted, term-outside pages only")
            #expect(r.terms == ["INTERNAL", "CONFIDENTIAL"], "\(mode): page order, deduplicated")
        }

        // A single page, the singular phrase; the arm does not key on
        // documentHasRegions — the term came from an applied region even
        // when THIS page carries none.
        let single = fold([(2, .sensitiveTermOutsideRegions)],
                          mode: .secureRasterization, hasRegions: false,
                          terms: [2: ["CONFIDENTIAL"]])
        #expect(single.status.isAttention, "got \(single.status)")
        #expect(message(single.status) ==
            "Text matching your redactions is still readable on page 2 — read by OCR outside every redacted region")
        #expect(single.pages == [1])
        #expect(single.terms == ["CONFIDENTIAL"])

        // No term texts supplied (fold-only caller): still ATTENTION, terms nil
        // so the results row falls back to the layer's own description.
        let bare = fold([(1, .sensitiveTermOutsideRegions)], mode: .secureRasterization)
        #expect(bare.status.isAttention, "got \(bare.status)")
        #expect(bare.terms == nil)
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

    /// The signal→bucket mapping matrix. `.sensitiveTermOutsideRegions` keeps
    /// its own bucket on BOTH page modes (the attention arm), the generic
    /// outside-text signal folds generic, and in-region signals keep their
    /// mode-keyed buckets. Red→green pinned against the earlier engine, which
    /// folded the term-outside signal into the generic outside bucket.
    @Test("signal→bucket mapping: term-outside keeps its own bucket on both modes; in-region stays mode-keyed")
    func pageBucketMapping() {
        typealias Finding = VerificationEngine.PageOCRFinding
        func bucket(_ f: Finding, _ m: PipelineMode) -> Bucket {
            VerificationEngine.pageBucket(for: f, effectiveMode: m)
        }
        for mode in [PipelineMode.secureRasterization, .searchableRedaction] {
            #expect(bucket(.sensitiveTermInRegion, mode) == .sensitiveTermInRegion)
            #expect(bucket(.fillArtifactInRegion, mode) == .fillArtifactInRegion)
            #expect(bucket(.sensitiveTermOutsideRegions, mode) == .sensitiveTermOutsideRegions,
                    "the term-outside signal keeps its own bucket on \(mode)")
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
