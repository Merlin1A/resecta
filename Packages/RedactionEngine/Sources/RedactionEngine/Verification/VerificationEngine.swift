import Foundation
import PDFKit
import Vision
import ImageIO
#if canImport(UIKit)
import UIKit  // PDFPage.thumbnail(of:for:) returns UIImage
#else
import AppKit  // macOS tooling destination: thumbnail returns NSImage
#endif

// ENGINE §6.1–§6.9 — Verification engine with 5 base layers
// (+ 3 sandwich-specific in Phase 7; +Layer 9 lineage in M1; +Layer 10
// operator re-extraction in M3 — Searchable only, total 10).

/// Stateless verification engine. Runs individual layers on output PDFs.
/// See ENGINE §6.7a for the public API contract.
public struct VerificationEngine: Sendable {

    /// Confidence threshold for Layer 2 OCR check (ENGINE §6.2).
    /// 0.50 is standard for text recognition — reduces noise from bitmap
    /// artifacts while still catching leaked text.
    private static let ocrConfidenceThreshold: Float = 0.50

    /// FAIL confidence gate for a sensitive-term-in-region hit.
    /// Equal to `ocrConfidenceThreshold` so the FAIL is double-gated (region
    /// overlap AND term match); exposed as its own constant so an
    /// adjustment to a stricter value (e.g. 0.75) is a one-line change.
    private static let sensitiveTermFailConfidenceThreshold: Float = ocrConfidenceThreshold

    /// Minimum fraction of an OCR word/line box that must lie inside a redacted
    /// region for the hit to count as "in region" (ENGINE §6.2). Replaces the
    /// prior any-overlap test (`CGRect.intersects`), under which the bounding box
    /// of an adjacent still-visible word clipping a mid-line region's edge by a
    /// sliver counted as in-region. In Secure Rasterization the region is painted
    /// opaque (`PageRasterizer.applyRedactionFills`, blend `.copy`) and post-fill
    /// `verifyFill` proves the pixels are the fill colour, so no readable glyph
    /// can sit inside a correctly-filled region — the only box that can touch a
    /// region edge is neighbouring text. A real paint miss leaves glyphs
    /// substantially inside the region (fraction → 1.0, still a FAIL); an
    /// edge-clipping sliver is a small fraction (≪ 0.5) and is dropped. Threshold
    /// is inclusive (`>=`). See 00-DIAGNOSIS / 01-FIX (2026-06-25).
    private static let inRegionCoverageThreshold: CGFloat = 0.5

    /// Bounded width for the Layer-2 OCR task group. Vision's own
    /// internal concurrency bounds the realized speed-up; a private constant so
    /// tuning needs no source-logic change. It is a `nonisolated(unsafe) static
    /// var` purely so the wall-clock acceptance gate can measure width-1 (serial)
    /// against width-3 on the one production code path — production never mutates
    /// it (the perf test is `.serialized` + `.disabled`, run on demand alone).
    /// S3 rider: the width bounds pages-resident memory and the overlap of
    /// extraction/sampling/classification; the Vision perform itself is
    /// serialized on `visionPerformQueue` (see `layer2OCRHits`), so width no
    /// longer multiplies concurrent Vision sync-waits.
    nonisolated(unsafe) static var ocrParallelism = 3

    /// Layer-2 OCR downsample cap (largest pixel dimension). Matches
    /// detection rasterization's 4096-px ceiling (`DetectionRenderPolicy
    /// .maxDetectionPixels`): the OCR check looks for READABLE
    /// leaked text, not pixel fidelity, so a page rendered far above this is
    /// downsampled before Vision. Vision's normalized observation coordinates are
    /// scale-invariant, so the Layer-2 identity contract is unaffected.
    private static let ocrMaxPixelDimension = 4096

    public init() {}

    /// Test seam: observes the `PDFDocument` identity each
    /// `runLayer` call receives, so a guard test can assert the parallel base
    /// batch gives each layer its own instance (no shared-PDFKit-object
    /// concurrency). Nil in production — the `?.` invocation below compiles to a
    /// no-op. `VerificationEngine` is a value type, so set this on the verifier
    /// value BEFORE passing it into `collectParallelBaseLayerResults`; the
    /// per-task copies the fan-out makes each carry the closure (ADV-2 A2-10).
    public var onRunLayerDispatch: (@Sendable (Int, ObjectIdentifier) -> Void)?

    /// Total layer count for a given pipeline mode (R4: never hardcoded).
    public func layerCount(for mode: PipelineMode) -> Int {
        switch mode {
        case .secureRasterization: 5
        case .searchableRedaction: 10
        }
    }

    /// Human-readable name for the layer at the given index.
    /// See ENGINE §6.8 for SF Symbol mapping.
    public func layerName(at index: Int) -> String {
        switch index {
        case 0: "Text Extraction"
        case 1: "OCR Check"
        case 2: "Binary String Search"
        case 3: "Structure Check"
        case 4: "Metadata Check"
        case 5: "Spatial Verification"
        case 6: "Character Count"
        case 7: "Font Verification"
        case 8: "Character Lineage"
        case 9: "Operator Re-Extraction"
        default: "Unknown Layer"
        }
    }

    /// SF Symbol name for the layer (ENGINE §6.8).
    public func layerSymbol(at index: Int) -> String {
        switch index {
        case 0: "doc.text.magnifyingglass"
        case 1: "text.viewfinder"
        case 2: "01.rectangle.fill"
        case 3: "rectangle.3.group"
        case 4: "info.circle"
        case 5: "character.textbox"
        case 6: "number"
        case 7: "textformat"
        case 8: "checkmark.seal"
        case 9: "doc.text.below.ecg"
        default: "questionmark.circle"
        }
    }

    /// Convenience for callers holding a plain term list: every term keeps
    /// substring matching (`requiresTokenBoundary` false), which is the
    /// pre-`SensitiveTerm` behavior byte for byte.
    ///
    /// `@_disfavoredOverload` so an empty-array literal resolves to the
    /// `[SensitiveTerm]` overload instead of being ambiguous; the two are
    /// interchangeable when empty.
    @_disfavoredOverload
    @concurrent
    public func runLayer(
        _ layerIndex: Int,
        outputDocument: SendablePDFDocument,
        sourcePageCount: Int,
        regions: [Int: [RedactionRegion]],
        sensitiveTerms: [String],
        pipelineMode: PipelineMode,
        filterDigests: [PageFilterDigest?],
        perPageModes: [PipelineMode]
    ) async -> LayerResult {
        await runLayer(
            layerIndex,
            outputDocument: outputDocument,
            sourcePageCount: sourcePageCount,
            regions: regions,
            sensitiveTerms: sensitiveTerms.map { SensitiveTerm(text: $0) },
            pipelineMode: pipelineMode,
            filterDigests: filterDigests,
            perPageModes: perPageModes
        )
    }

    /// Run a single verification layer.
    /// See ENGINE §6.7a for parameter documentation.
    @concurrent
    public func runLayer(
        _ layerIndex: Int,
        outputDocument: SendablePDFDocument,
        sourcePageCount: Int,
        regions: [Int: [RedactionRegion]],
        sensitiveTerms: [SensitiveTerm],
        pipelineMode: PipelineMode,
        filterDigests: [PageFilterDigest?],
        perPageModes: [PipelineMode]
    ) async -> LayerResult {
        // R4 / CLAUDE.md §49: the valid layer-index range is mode-dependent
        // (5 for .secureRasterization, 10 for .searchableRedaction). A
        // silent .pass on an out-of-range index would let caller bugs
        // masquerade as verification success. Fail fast instead.
        precondition(
            layerIndex >= 0 && layerIndex < layerCount(for: pipelineMode),
            "runLayer called with out-of-range layerIndex \(layerIndex) for mode \(pipelineMode)"
        )

        let start = CFAbsoluteTimeGetCurrent()
        let doc = outputDocument.document

        // Guard seam: record which document instance this layer was
        // dispatched against. No-op in production (closure is nil).
        onRunLayerDispatch?(layerIndex, ObjectIdentifier(doc))

        let sandwichVerifier = SandwichVerification()

        var status: VerificationStatus
        var layerPageReferences: [Int]? = nil
        // Display-only term texts behind an `.attention` result (Layers 3 and
        // 10) — threaded into LayerResult.reviewTermTexts; nil elsewhere.
        var layerReviewTerms: [String]? = nil

        // PERF-8 / CANCEL-001..007: Each layer method calls
        // `try Task.checkCancellation()` on entry (and within long inner
        // loops for layers that walk many pages or characters). A
        // CancellationError thrown from a layer is converted below into a
        // `.skipped` LayerResult so the coordinator's between-layer
        // `try Task.checkCancellation()` then surrenders the pipeline.
        // Keeps `runLayer`'s public signature non-throwing.
        do { // LegalPhrases:safe (Swift keyword usage below)
            switch layerIndex {
            case 0:
                let (s0, pages0) = try runLayer1TextExtraction(doc, pipelineMode: pipelineMode, regions: regions)
                status = s0
                layerPageReferences = pages0
            case 1:
                // Layer 2's OCR gate applies the same per-term boundary
                // discipline as the byte layers (String-space mirror in
                // `containsTerm`), so a boundary-required name term cannot
                // substring-match inside an unrelated word read off a raster.
                let (s1, pages1) = try await runLayer2OCR(
                    doc, pipelineMode: pipelineMode,
                    regions: regions, sensitiveTerms: sensitiveTerms,
                    perPageModes: perPageModes)
                status = s1
                layerPageReferences = pages1
            case 2:
                let (s2, pages2, terms2) = try runLayer3BinarySearch(doc, sensitiveTerms: sensitiveTerms)
                status = s2
                layerPageReferences = pages2
                layerReviewTerms = terms2
            case 3:
                let (s, pages) = try runLayer4Structural(doc)
                status = s
                layerPageReferences = pages
            case 4:
                status = try runLayer5Metadata(doc)
            // Layers 6–10: Sandwich-specific (ENGINE §6.6)
            // Only run for Searchable Redaction pages.
            case 5:
                let (s5, pages5) = try await runLayer6SpatialVerification(
                    doc, regions: regions, perPageModes: perPageModes,
                    verifier: sandwichVerifier)
                status = s5
                layerPageReferences = pages5
            case 6:
                let (s6, pages6) = try await runLayer7CharacterCount(
                    doc, filterDigests: filterDigests, perPageModes: perPageModes,
                    verifier: sandwichVerifier)
                status = s6
                layerPageReferences = pages6
            case 7:
                let (s7, pages7) = try await runLayer8FontVerification(
                    doc, perPageModes: perPageModes, verifier: sandwichVerifier)
                status = s7
                layerPageReferences = pages7
            case 8:
                let (s8, pages8) = try await runLayer9CharacterLineage(
                    doc, filterDigests: filterDigests, perPageModes: perPageModes,
                    verifier: sandwichVerifier)
                status = s8
                layerPageReferences = pages8
            case 9:
                // Layer 10 (ENGINE §6.6 SVT-5) — operator-semantic re-extraction.
                // Independent of `regions`, `perPageModes`, `filterDigests`, and
                // `sourcePageCount`: walks the output content streams directly.
                // Pairs with Layer 3 SVT-3 as a two-decoder cross-check.
                let l10 = await sandwichVerifier.verifyTextOperatorSemantics(
                    outputDocument: outputDocument,
                    sensitiveTerms: sensitiveTerms
                )
                status = l10.status
                layerPageReferences = l10.pageReferences
                layerReviewTerms = l10.reviewTermTexts
            default:
                preconditionFailure("Unreachable — precondition at top of runLayer enforces range")
            }
        } catch is CancellationError { // LegalPhrases:safe (Swift keyword)
            let duration = CFAbsoluteTimeGetCurrent() - start
            let name = layerName(at: layerIndex)
            let symbol = layerSymbol(at: layerIndex)
            return LayerResult(
                name: name, symbolName: symbol, status: .skipped,
                shortDescription: "Skipped.",
                detailDescription: "\(name) was not run because the operation was cancelled.",
                pageReferences: nil, durationSeconds: duration
            )
        } catch { // LegalPhrases:safe (Swift keyword)
            // Unexpected non-cancellation error — surface as fail so caller sees
            // something went wrong rather than silently passing.
            let duration = CFAbsoluteTimeGetCurrent() - start
            let name = layerName(at: layerIndex)
            let symbol = layerSymbol(at: layerIndex)
            return LayerResult(
                name: name, symbolName: symbol,
                status: .fail("Layer threw unexpected error"),
                shortDescription: "Layer threw unexpected error.",
                detailDescription: "\(name) threw an unexpected error while checking the document.",
                pageReferences: nil, durationSeconds: duration
            )
        }

        let duration = CFAbsoluteTimeGetCurrent() - start
        let name = layerName(at: layerIndex)
        let symbol = layerSymbol(at: layerIndex)

        var shortDesc: String
        var detailDesc: String
        switch status {
        case .pass:
            shortDesc = "No issues found."
            detailDesc = "\(name) completed with no findings."
        case .warn(let msg):
            shortDesc = msg
            detailDesc = "\(name) found a non-critical issue: \(msg)"
        case .info(let msg):
            shortDesc = msg
            detailDesc = "\(name) reported informational metadata: \(msg)"
        case .attention(let msg):
            shortDesc = msg
            detailDesc = "\(name) flagged text for review: \(msg)"
        case .fail(let msg):
            shortDesc = msg
            detailDesc = "\(name) found a critical issue: \(msg)"
        case .skipped:
            shortDesc = "Skipped."
            detailDesc = "\(name) was not applicable for this pipeline mode."
        }

        // WP9c: For Layer 7 (Character Count), surface boundary character count
        // when passing — helps users understand near-miss proximity to redacted regions.
        // Promoted to .info so the row lands in the METADATA group rather than
        // silently inflating the "passed" count.
        if layerIndex == 6, status == .pass {
            let totalBoundary = filterDigests.compactMap { $0 }
                .reduce(0) { $0 + $1.boundaryCharacters.count }
            if totalBoundary > 0 {
                shortDesc = "\(totalBoundary) character\(totalBoundary == 1 ? "" : "s") near redaction boundaries."
                detailDesc = "\(name) completed with no findings. \(totalBoundary) character\(totalBoundary == 1 ? "" : "s") detected near redaction boundaries."
                status = .info(shortDesc)
            }
        }

        return LayerResult(
            name: name, symbolName: symbol, status: status,
            shortDescription: shortDesc, detailDescription: detailDesc,
            pageReferences: layerPageReferences, durationSeconds: duration,
            reviewTermTexts: layerReviewTerms
        )
    }

    /// Aggregate per-layer results into overall status (ENGINE §6.7).
    /// Any FAIL → overall FAIL. Else any ATTENTION → overall ATTENTION
    /// (un-redacted residual text — user-recoverable, so it outranks notes
    /// but never masks an output defect). Else any WARN → overall WARN.
    /// All PASS → overall PASS.
    /// Uses .isFail/.isWarn helpers instead of Equatable (which ignores associated values)
    /// to avoid fragile matching and preserve the actual diagnostic message.
    public func aggregateStatus(_ layers: [LayerResult]) -> VerificationStatus {
        if let firstFail = layers.first(where: { $0.status.isFail }) {
            if case .fail(let msg) = firstFail.status {
                return .fail(msg)
            }
            return .fail("Verification failed")
        }
        if let firstAttention = layers.first(where: { $0.status.isAttention }) {
            if case .attention(let msg) = firstAttention.status {
                return .attention(msg)
            }
            return .attention("Verification reported items to review")
        }
        if let firstWarn = layers.first(where: { $0.status.isWarn }) {
            if case .warn(let msg) = firstWarn.status {
                return .warn(msg)
            }
            return .warn("Verification produced warnings")
        }
        // Account for .skipped layers so a
        // partially- or wholly-skipped verdict is not reported as PASS. All
        // layers skipped → .skipped (preserves the VerificationReport.skipped
        // sentinel); some but not all skipped → .warn. Count-agnostic — never
        // assumes a 5- or 10-layer total.
        let skippedCount = layers.filter { $0.status.isSkipped }.count
        if skippedCount > 0 {
            if skippedCount == layers.count {
                return .skipped
            }
            return .warn("Some verification checks were skipped — results may be incomplete")
        }
        return .pass
    }

    // MARK: - Layer 1: Text Extraction (ENGINE §6.1)

    /// Returns (status, affectedPages). Page-level findings (selectable text,
    /// annotations) are accumulated across ALL pages — not returned at the
    /// first offending page — so a multi-page problem surfaces in one run,
    /// and the 0-based page list feeds the tappable page chips in the UI.
    /// Document-level findings (bookmarks, AcroForm) carry nil references.
    private func runLayer1TextExtraction(
        _ doc: PDFDocument,
        pipelineMode: PipelineMode,
        regions: [Int: [RedactionRegion]]
    ) throws -> (VerificationStatus, [Int]?) {
        // PERF-8 / CANCEL-001: entry-level cooperative cancellation.
        try Task.checkCancellation()
        var selectableTextPages: [Int] = []
        var annotationPages: [Int] = []
        // VQ-23: pages PDFKit cannot open were previously skipped silently and
        // folded into a clean PASS. Collect them; when the layer would
        // otherwise PASS, they surface as a WARN (Layer 10's per-page
        // unavailability shape). Real leaks below still outrank the WARN.
        var unreadablePages: [Int] = []
        for i in 0..<doc.pageCount {
            try Task.checkCancellation()
            guard let page = doc.page(at: i) else {
                unreadablePages.append(i)
                continue
            }

            // Check for selectable text
            if let text = page.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if pipelineMode == .secureRasterization {
                    selectableTextPages.append(i)
                }
                // Searchable Redaction: text is expected, but verify none in redacted areas
                // Full spatial verification is Layer 6 (Phase 7)
            }

            // Check for annotations
            if !page.annotations.isEmpty {
                annotationPages.append(i)
            }
        }

        // Category priority for the verdict message is unchanged:
        // text > annotations > bookmarks > AcroForm.
        if !selectableTextPages.isEmpty {
            let list = selectableTextPages.map { String($0 + 1) }.joined(separator: ", ")
            return (.fail("Selectable text found on \(pagePhrase(selectableTextPages, list: list))"),
                    selectableTextPages)
        }
        if !annotationPages.isEmpty {
            let list = annotationPages.map { String($0 + 1) }.joined(separator: ", ")
            return (.fail("Annotations found on \(pagePhrase(annotationPages, list: list))"),
                    annotationPages)
        }

        // Check document-level structures
        if doc.outlineRoot != nil {
            return (.fail("Bookmarks found in output"), nil)
        }

        // Check for /AcroForm via CGPDFDocument. A silent no-op on any nil
        // in this chain would mask AcroForm presence — Layer 4 handles the
        // identical failure mode by returning .warn, so match that here.
        guard let url = doc.documentURL,
              let cgDoc = CGPDFDocument(url as CFURL),
              let catalog = cgDoc.catalog else {
            return (.warn("Could not verify /AcroForm absence"), nil)
        }
        var acroForm: CGPDFDictionaryRef?
        if CGPDFDictionaryGetDictionary(catalog, "AcroForm", &acroForm) {
            return (.fail("Form fields found in output"), nil)
        }

        // VQ-23: no leak reported, but some pages were never inspected —
        // an honest WARN, not a clean PASS.
        if !unreadablePages.isEmpty {
            return (unreadablePagesWarn(unreadablePages), unreadablePages)
        }
        return (.pass, nil)
    }

    // MARK: - Layer 2: OCR on Output (ENGINE §6.2)

    /// A single Layer-2 OCR observation, reduced to a plain value type so the
    /// classification logic is unit-testable without Vision. Boxes are normalized
    /// (0–1, **bottom-left origin**) — the SAME convention as
    /// `RedactionRegion.normalizedRect` (`RedactionRegion.swift:33`). The Vision
    /// `boundingBox` → region mapping is the IDENTITY, NOT a y-flip (pinned
    /// by the coordinate-convention guard tests).
    /// Part A: per-box, full-RGB fill statistics for the chroma-aware
    /// fill-consistency guard. Computed over the IN-REGION PORTION of the box
    /// (box ∩ region-rect, Option A — see `enrichWithFillSamples`) against the
    /// region's self-calibrated fill colour. All values are 0…1; distance is the
    /// per-channel (Chebyshev) RGB distance from the fill, so a coloured glyph
    /// whose luminance ≈ the fill (e.g. navy on black) still reads as contrast — a
    /// luminance-only test would mis-classify it as fill. See `isFillConsistent` /
    /// `boxFillSample`.
    struct BoxFillSample: Sendable {
        /// Share of SAMPLED pixels (the in-region portion, box ∩ region-rect)
        /// within `fillDistance` of the fill colour.
        let fillFraction: CGFloat
        /// Share at/over `contrastDistance`. The contrast band reaches DOWN to at
        /// least the fill band's edge (`contrastDistance <= fillDistance`), so no
        /// pixel falls in a gap between the two (the no-dead-zone invariant).
        let contrastFraction: CGFloat
        /// Largest single-pixel distance from the fill — the outlier floor: the
        /// dark/contrasting core of any real glyph deviates strongly even when it
        /// is too thin to move `contrastFraction`.
        let maxDeviation: CGFloat
    }

    struct OCRHit: Sendable {
        /// Line-level observation box; the conservative intersection fallback.
        let box: CGRect
        /// Per-word boxes when obtainable (ADV-2 A2-3); empty → use `box`.
        let wordBoxes: [CGRect]
        /// Top-candidate recognized string, for sensitive-term matching.
        let text: String?
        /// Observation confidence (already ≥ `ocrConfidenceThreshold` for any
        /// constructed hit); re-checked against the FAIL gate at classification.
        let confidence: Float
        /// Part A: per-box full-RGB fill samples, index-PARALLEL to
        /// `inRegionCandidateBoxes(of:)`. EMPTY ⇒ fill is unknown ⇒ the classifier
        /// excludes nothing and behaves exactly as before (keeps the pure
        /// classifier unit tests, which never set this, unaffected).
        let boxFill: [BoxFillSample]

        /// `boxFill` defaults to empty so every existing construction
        /// (`OCRHit(box:wordBoxes:text:confidence:)`) is unchanged; only the
        /// fill-sampling site supplies it.
        init(box: CGRect, wordBoxes: [CGRect], text: String?, confidence: Float,
             boxFill: [BoxFillSample] = []) {
            self.box = box
            self.wordBoxes = wordBoxes
            self.text = text
            self.confidence = confidence
            self.boxFill = boxFill
        }
    }

    /// Per-page Layer-2 verdict. Classified per page with priority
    /// `sensitiveTermInRegion > textInRegion > fillArtifactInRegion >
    /// sensitiveTermOutsideRegions > textOutsideRegionsOnly > none`; the
    /// cross-page layer fold (`foldLayer2PageOutcomes`) then places the
    /// warnable out-of-region arms ahead of the fill-artifact note — see the
    /// priority-fold comment there.
    /// `fillArtifactInRegion` (Part A) is an in-region OCR hit proven to be a
    /// Vision hallucination off the SOLID fill — it DEMOTES the would-be
    /// FAIL/WARN to an informational note, and never silences a hit: it
    /// outranks `textOutsideRegionsOnly` in both orders, so a page carrying it
    /// can never fold to a clean PASS. `sensitiveTermOutsideRegions` marks a page where a sensitive term
    /// is readable OUTSIDE every region — on a rasterized page OCR is the only
    /// reader that can notice a term the user redacted surviving elsewhere
    /// (e.g. a displaced fill); the mode-aware bucketing in
    /// `classifyPageImages` keeps Searchable pages on the generic
    /// outside-regions path (Layers 3/10 own the text layer there).
    enum PageOCRFinding: Sendable, Equatable {
        case sensitiveTermInRegion
        case textInRegion
        case fillArtifactInRegion
        case sensitiveTermOutsideRegions
        case textOutsideRegionsOnly
        case none
    }

    /// ADV-2 A2-4: build the Layer-2 region set through the SAME K3.1 sliver
    /// predicate the fill path uses (`PipelineCoordinator.buildPDFPageData`):
    /// drop regions with `normalizedRect.width/height <= 0.001`, clamp survivors.
    /// Painter and verifier then see one region set — a sub-threshold sliver the
    /// engine refuses to fill never produces a Layer-2 WARN/FAIL describing a
    /// region that was never redacted.
    static func layer2RegionSnapshot(_ regions: [RedactionRegion]) -> [RedactionRegion] {
        regions.compactMap { region in
            guard region.normalizedRect.width > 0.001,
                  region.normalizedRect.height > 0.001 else { return nil }
            var clamped = region
            clamped.normalizedRect = region.normalizedRect.clampedToNormalized()
            return clamped
        }
    }

    /// Pure Layer-2 classifier. An OCR hit is "in region" when any of
    /// its boxes has at least `inRegionCoverageThreshold` of its own area inside
    /// a region's `normalizedRect` (identity space) — meaningful containment, not
    /// a sliver edge touch — AND, for a polygon region
    /// the box intersects the vertex polygon itself: the rect is only
    /// the polygon's bounding box, and text inside bbox-minus-polygon is page
    /// content the user chose to keep. FAIL when a sensitive term is
    /// readable inside a redacted region; WARN for any other in-region text; text
    /// only outside regions is the page's own (un-redacted) content. No Vision
    /// dependency — fully unit-testable.
    /// `[String]` compatibility overload: bare string terms keep their
    /// substring semantics (no boundary flag), exactly the pre-model behavior.
    @_disfavoredOverload
    static func classifyPageOCR(
        hits: [OCRHit],
        pageRegions: [RedactionRegion],
        sensitiveTerms: [String]
    ) -> PageOCRFinding {
        classifyPageOCR(
            hits: hits, pageRegions: pageRegions,
            sensitiveTerms: sensitiveTerms.map { SensitiveTerm(text: $0) })
    }

    static func classifyPageOCR(
        hits: [OCRHit],
        pageRegions: [RedactionRegion],
        sensitiveTerms: [SensitiveTerm]
    ) -> PageOCRFinding {
        // ADV-2 A2-3: mirror Layer 3's length filter (shared
        // `AhoCorasick.isSearchableTerm`). The memo's "filtered upstream ≥4"
        // cited spec text, not code — this helper receives raw terms.
        let validTerms = sensitiveTerms.filter { AhoCorasick.isSearchableTerm($0.text) }

        var sawTextInRegion = false
        var sawFillArtifactInRegion = false
        var sawSensitiveTermOutsideRegions = false
        var sawTextOutsideRegions = false

        for hit in hits {
            // ADV-2 A2-3: intersect WORD-level boxes when obtainable so a line
            // observation spanning a filled region (e.g. "John █████ Doe") does
            // not false-intersect on the survivors; fall back to the line box.
            // Part A: `boxFill` is index-parallel to these boxes (empty ⇒ unknown).
            let boxes = inRegionCandidateBoxes(of: hit)
            let samples = hit.boxFill

            var hitHasReadableInRegionBox = false
            var hitHasFillArtifactInRegionBox = false
            var hitHasOutOfRegionBox = false

            for (index, box) in boxes.enumerated() {
                // Require MEANINGFUL containment, not
                // an any-overlap edge touch. A still-visible word whose box clips a
                // mid-line region's edge by a sliver is not in-region; a box that is
                // substantially inside (a paint miss) still is. One word box over the
                // bar pulls the hit in. See `inRegionCoverageThreshold`.
                let inRegion = pageRegions.contains { region in
                    guard coverageFraction(of: box, inside: region.normalizedRect)
                            >= inRegionCoverageThreshold else { return false }
                    // A polygon region's `normalizedRect` is only its
                    // bounding box — text the user deliberately preserved
                    // inside bbox-minus-polygon (an L-shape's notch) is NOT
                    // redacted content. Require the box to also intersect the
                    // polygon itself (same normalized space; shared geometry
                    // with the character filter and Layer 6). Rect-only
                    // regions (`vertices == nil` or < 3) take the unchanged
                    // rect-coverage path above.
                    guard let vertices = region.vertices, vertices.count >= 3 else { return true }
                    return rectIntersectsPolygon(box, vertices: vertices)
                }
                if inRegion {
                    // Part A: distinguish a fill artifact (Vision read a token off
                    // the SOLID bar — full-RGB fill-consistent on its in-region portion) from
                    // readable in-region ink. A fill-consistent box is DEMOTED (it
                    // raises only the fill-artifact signal below, which can never be
                    // a clean PASS), never silenced. Unknown sample (empty boxFill)
                    // ⇒ treat as readable — exactly today's behaviour.
                    let fillConsistent = index < samples.count && isFillConsistent(samples[index])
                    if fillConsistent {
                        hitHasFillArtifactInRegionBox = true
                    } else {
                        hitHasReadableInRegionBox = true
                    }
                } else {
                    // The hit's own (un-redacted) content, or the out-of-rect strokes
                    // of a straddle hit. Evaluated per box, so a demoted in-region
                    // box never short-circuits the hit and masks a sibling box that
                    // is genuinely outside every region (demote-never-silence).
                    sawTextOutsideRegions = true
                    hitHasOutOfRegionBox = true
                }
            }

            // A hit with readable strokes outside every region whose text matches
            // a sensitive term (same confidence gate and term filter as the
            // in-region FAIL above): the term the user redacted is still readable
            // somewhere on the page. Signal only — the fold decides the tier, and
            // only rasterized pages surface it (see PageOCRFinding doc).
            if hitHasOutOfRegionBox,
               hit.confidence >= sensitiveTermFailConfidenceThreshold,
               let text = hit.text,
               validTerms.contains(where: { containsTerm(text, $0) }) {
                sawSensitiveTermOutsideRegions = true
            }

            if hitHasReadableInRegionBox {
                sawTextInRegion = true
                // FAIL only when a known sensitive term is readable inside the
                // region AND the hit clears the FAIL confidence gate. A
                // purely fill-consistent hit never reaches here, so a token
                // hallucinated off the bar that happens to match a term cannot FAIL
                // — there is no readable ink to leak.
                if hit.confidence >= sensitiveTermFailConfidenceThreshold,
                   let text = hit.text,
                   validTerms.contains(where: { containsTerm(text, $0) }) {
                    return .sensitiveTermInRegion   // fail outranks every other case
                }
            } else if hitHasFillArtifactInRegionBox {
                sawFillArtifactInRegion = true
            }
        }

        if sawTextInRegion { return .textInRegion }
        if sawFillArtifactInRegion { return .fillArtifactInRegion }
        if sawSensitiveTermOutsideRegions { return .sensitiveTermOutsideRegions }
        if sawTextOutsideRegions { return .textOutsideRegionsOnly }
        return .none
    }

    /// Case-insensitive term containment pinned to en_US_POSIX. Replaces
    /// `localizedCaseInsensitiveContains`, whose fold follows the device
    /// locale — under Turkish casing rules a dotless-I term can silently
    /// fail to match. Case-only by design: diacritic-insensitivity would
    /// false-match distinct names.
    static func containsTermCaseInsensitive(_ text: String, _ term: String) -> Bool {
        text.range(of: term, options: .caseInsensitive,
                   locale: Locale(identifier: "en_US_POSIX")) != nil
    }

    /// Term containment with the model's boundary discipline — the
    /// String-space mirror of `SensitiveTermAutomaton.tokenFilteredMatches`'
    /// byte rule: a boundary-required match counts only when the characters
    /// adjacent to it are non-alphanumeric ASCII or absent (whitespace,
    /// punctuation, text edges, and non-ASCII characters all bound a token).
    /// Substring terms keep `containsTermCaseInsensitive` semantics.
    static func containsTerm(_ text: String, _ term: SensitiveTerm) -> Bool {
        guard term.requiresTokenBoundary else {
            return containsTermCaseInsensitive(text, term.text)
        }
        func embedsToken(_ character: Character) -> Bool {
            guard character.unicodeScalars.count == 1,
                  let scalar = character.unicodeScalars.first, scalar.isASCII
            else { return false }
            return (scalar.value >= 0x30 && scalar.value <= 0x39)
                || (scalar.value >= 0x41 && scalar.value <= 0x5A)
                || (scalar.value >= 0x61 && scalar.value <= 0x7A)
        }
        var searchRange = text.startIndex..<text.endIndex
        while let match = text.range(
            of: term.text, options: .caseInsensitive, range: searchRange,
            locale: Locale(identifier: "en_US_POSIX")) {
            let boundedBefore = match.lowerBound == text.startIndex
                || !embedsToken(text[text.index(before: match.lowerBound)])
            let boundedAfter = match.upperBound == text.endIndex
                || !embedsToken(text[match.upperBound])
            if boundedBefore && boundedAfter { return true }
            searchRange = match.upperBound..<text.endIndex
        }
        return false
    }

    /// Fraction of `box` that lies inside `region` (both in identity space, 0–1
    /// bottom-left). Returns 0 when the rectangles are disjoint or `box` is
    /// degenerate (zero area). Used by `classifyPageOCR` to require meaningful
    /// containment instead of an any-overlap edge touch (ENGINE §6.2; see
    /// `inRegionCoverageThreshold`). `static` so the coverage math has a direct
    /// unit test.
    static func coverageFraction(of box: CGRect, inside region: CGRect) -> CGFloat {
        let boxArea = box.width * box.height
        guard boxArea > 0 else { return 0 }
        let overlap = box.intersection(region)
        guard !overlap.isNull else { return 0 }
        return (overlap.width * overlap.height) / boxArea
    }

    // MARK: - Layer-2 fill-consistency guard (Part A — chroma-aware, demote-never-silence)
    //
    // Secure Rasterization paints solid, `verifyFill`-proven fill bars (black OR
    // white). Vision, OCRing the rasterized output with the frozen preset,
    // hallucinates short tokens OUT OF the bars; their boxes sit ≥ 0.5 inside the
    // (correct) region rect → a secure-raster FAIL with no surviving PII. This
    // guard tells such a fill artifact (near-uniform fill, no readable contrast)
    // from genuine in-region ink, and DEMOTES the false FAIL to an informational
    // note. It can never silence a real leak: real readable ink — including
    // coloured ink whose luminance ≈ the fill — necessarily lands in the contrast
    // band or trips the outlier floor, so it is KEPT; and a demoted box still
    // yields at least an informational note in Verification Details (it can never
    // produce a silent clean PASS). Thresholds were landed at the original
    // strict values in S2 and FINALIZED UNCHANGED by the S3 adversarial battery
    // (`Layer2FillGuardBatteryTests`, iOS 26.4): the real drivers measure
    // byte-exact fill (1.000 / 0.000 / maxDev ≤ 0.012) while every readable-leak
    // class the battery could surface through Vision holds a wide margin on at
    // least one floor (per-constant margins below). Demotion tier (updated
    // 2026-07-09): the demotion folds to an informational note — visible in
    // Verification Details, never affecting pass/fail — on BOTH page modes; any
    // further promotion of provable tier-1 boxes (e.g. suppressing the note
    // entirely) is a policy change reserved to Jesse.
    // See plans/resecta-partA-verifier-guard-2026-06-27/.

    /// Δ_fill — full-RGB (per-channel Chebyshev) distance within which a pixel is
    /// "essentially the fill colour"; generous enough to absorb JPEG q0.92 noise
    /// on a solid bar. 0…1. S3 band pin: a uniform dev-0.149 field still counts
    /// as fill, dev-0.1725 does not (battery `propertyFloors_pure`).
    private static let fillDistance: CGFloat = 0.16
    /// Δ_contrast — distance at/over which a pixel counts as readable contrast.
    /// MUST be ≤ `fillDistance` (asserted in `isFillConsistent`) so the bands are
    /// complementary — no dead zone a pale-but-readable stroke can hide in. Set
    /// below the readability JND and above JPEG noise. 0…1. S3 margins: the
    /// palest Vision-readable ink the battery measured deviates ≥ 0.176
    /// (gray-45 on black; pale-on-white F-WEBER ink deviates ≈ 0.18 with its
    /// loose-band break only at a hypothetical Δ_contrast ≥ 44/255 ≈ 0.173 —
    /// unreachable while Δ_contrast ≤ Δ_fill = 0.16 holds). Band pin: dev
    /// 0.1098 is fill-only; dev 0.1294 already counts as contrast.
    private static let contrastDistance: CGFloat = 0.12
    /// F_min — minimum in-region-portion fill fraction for a box to be a demotion
    /// candidate (efficacy floor). Because `contrastFraction >= 1 - fillFraction`
    /// (every non-fill pixel is a contrast pixel, given Δ_contrast ≤ Δ_fill),
    /// demotion already implies `fillFraction >= 1 - contrastCeil`. S3 margins:
    /// real drivers fill = 1.000 (margin 0.03 above); the fullest readable-leak
    /// box measured 0.938 (gray-45) — 0.032 below the floor. The battery's
    /// chroma×hairline probe (blue-115 ultralight, below Vision's `.fast`
    /// sensor floor) starves BOTH the recall floor (contrast 0.076) and the
    /// outlier floor (maxDev 0.470) at once — this fill floor is what refuses
    /// it, at 0.934 (margin 0.036): the tightest measured approach to the
    /// demotion region by any ink class.
    private static let fillFloor: CGFloat = 0.97
    /// C_max — maximum readable-contrast fraction for a demotion candidate
    /// (≤ 0.03 by charter). The binding safety constraint. S3 margins: drivers
    /// contrast = 0.000; the faintest readable-leak contrast measured 0.096
    /// (hairline ultralight digits) — 3.2× the ceiling, and that box is also
    /// refused by the fill floor (0.906) and the outlier floor (maxDev 0.986).
    private static let contrastCeil: CGFloat = 0.03
    /// Recall-floor invariant: a box with at least this much readable contrast is
    /// NEVER excluded, regardless of `fillFraction`. Structural — it holds even if
    /// `contrastCeil` were later loosened past it. Cannot be tuned away. S3: the
    /// battery's readable-leak contrast spans 0.096–0.995; the 0.096 hairline
    /// row rides the composed fill/outlier floors (see `contrastCeil`), every
    /// other class clears this floor outright.
    private static let recallFloor: CGFloat = 0.10
    /// Outlier floor: a single pixel this far (full-RGB) from the fill is
    /// "definitely ink" (the dark/contrasting core of a real glyph, including
    /// coloured ink whose luminance ≈ the fill) and blocks exclusion. 0…1.
    /// S3 margins: drivers maxDev ≤ 0.012 (0.488 below); hairline/reverse-video
    /// rims measure 0.867–1.000 (≥ 0.367 above); navy-on-black chroma ink
    /// (dev 0.338–0.455) sits under this floor and is carried by the recall
    /// floor instead — the floors compose per class.
    private static let strongInkDistance: CGFloat = 0.50
    /// Inset fraction (per side) for self-calibrating a region's fill colour —
    /// samples the rect's central interior, away from JPEG ringing at the edges.
    private static let fillCalibrationInset: CGFloat = 0.25
    /// Pixel margin trimmed from each edge of the in-region sample rect (box ∩
    /// region-rect, Option A) before sampling, to clear JPEG ringing / anti-alias
    /// overshoot at the bar↔rect boundary. Ringing is a fixed-WIDTH band, so a
    /// pixel inset — not a fraction of the (often tiny) box — is the correct shape;
    /// it leaves every numeric floor intact (preferred over loosening the outlier
    /// floor). Measured necessary on iOS 26.4: without it, boundary ringing spikes
    /// maxDeviation to ~1.0 on the narrow drivers (box flush with the rect edge,
    /// no overhang to clip) and blocks their demotion; with a 2 px trim every
    /// fixture driver demotes and the recall ink is still KEPT. S3 tiny-strip
    /// probes (battery `rider_insetTinyStrips`): interior hairline ink 2 px
    /// inside the sample edge survives the trim (contrast 0.125, maxDev 1.0 →
    /// KEPT); a 3 px strip collapses the inset and the un-inset fallback keeps
    /// the ink; ink hugging the strip's outer edge is trimmed and demotes —
    /// bounded at the fill-artifact WARN, never a clean PASS.
    private static let fillSampleInsetPixels: CGFloat = 2

    /// The candidate boxes an OCR hit contributes to the in-region decision: the
    /// per-word boxes when obtainable, else the conservative line box. SHARED by
    /// `classifyPageOCR` and the fill-sampling site so `OCRHit.boxFill` stays
    /// index-parallel to the boxes the classifier walks.
    static func inRegionCandidateBoxes(of hit: OCRHit) -> [CGRect] {
        hit.wordBoxes.isEmpty ? [hit.box] : hit.wordBoxes
    }

    /// A box is FILL-CONSISTENT — near-uniform fill carrying no readable contrast,
    /// i.e. a Vision hallucination off the solid bar rather than surviving ink —
    /// when it is overwhelmingly fill AND has negligible contrast AND has no
    /// strong-ink outlier. The recall- and outlier-floor branches make "never
    /// suppress readable ink" structural, not a function of threshold luck. PURE
    /// and unit-tested. The classifier may only ever DEMOTE such a box (FAIL →
    /// informational note); it can never silence it to a clean PASS.
    static func isFillConsistent(_ s: BoxFillSample) -> Bool {
        // Enforced no-dead-zone invariant: the contrast band must reach down to at
        // least the fill band's edge, so a readable-but-pale stroke cannot fall in
        // a gap between the bands. Not tunable past this point.
        precondition(contrastDistance <= fillDistance,
                     "Layer-2 fill guard: Δ_contrast must be ≤ Δ_fill (no dead zone)")
        if s.contrastFraction >= recallFloor { return false }   // recall floor — invariant
        if s.maxDeviation > strongInkDistance { return false }  // outlier floor — invariant
        return s.fillFraction >= fillFloor && s.contrastFraction <= contrastCeil
    }

    /// Full-RGB fill statistics for one OCR box over a BGRA pixel buffer (the
    /// layout `createBitmapContext` produces: byteOrder32Little +
    /// premultipliedFirst ⇒ B,G,R,A in memory). `box` is normalized **bottom-left**
    /// (the OCRHit / region convention) while buffer row 0 is the TOP scanline, so
    /// y flips via `(1 - maxY)` — identical to the verifier's proven grayscale fill
    /// probe. `fill` is the calibrated fill colour in 0…1 per channel. Distance is
    /// the per-channel Chebyshev (max |Δ| over R,G,B), so a coloured glyph whose
    /// luminance ≈ the fill still reads as contrast. `static` + buffer-pointer
    /// based so the pixel math is directly unit-testable without Vision (§3b).
    static func boxFillSample(
        box: CGRect,
        rgba: UnsafePointer<UInt8>,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        fill: (r: CGFloat, g: CGFloat, b: CGFloat)
    ) -> BoxFillSample {
        let x0 = max(0, Int(box.minX * CGFloat(width)))
        let x1 = min(width, Int(box.maxX * CGFloat(width)))
        let y0 = max(0, Int((1 - box.maxY) * CGFloat(height)))   // BL → top-down
        let y1 = min(height, Int((1 - box.minY) * CGFloat(height)))
        guard x1 > x0, y1 > y0 else {
            // Degenerate / off-image box → treat as definitely-ink so the guard
            // NEVER demotes it (precision-only floor).
            return BoxFillSample(fillFraction: 0, contrastFraction: 1, maxDeviation: 1)
        }
        var fillCount = 0, contrastCount = 0, total = 0
        var maxDev: CGFloat = 0
        for y in y0..<y1 {
            let rowBase = y * bytesPerRow
            for x in x0..<x1 {
                let off = rowBase + x * 4
                let b = CGFloat(rgba[off + 0]) / 255   // BGRA byte order
                let g = CGFloat(rgba[off + 1]) / 255
                let r = CGFloat(rgba[off + 2]) / 255
                let dev = max(abs(r - fill.r), abs(g - fill.g), abs(b - fill.b))
                total += 1
                if dev <= fillDistance { fillCount += 1 }
                if dev >= contrastDistance { contrastCount += 1 }
                if dev > maxDev { maxDev = dev }
            }
        }
        guard total > 0 else { return BoxFillSample(fillFraction: 0, contrastFraction: 1, maxDeviation: 1) }
        return BoxFillSample(
            fillFraction: CGFloat(fillCount) / CGFloat(total),
            contrastFraction: CGFloat(contrastCount) / CGFloat(total),
            maxDeviation: maxDev)
    }

    /// Self-calibrate a region's fill colour by averaging the BGRA buffer over the
    /// region rect's inset interior — the `verifyFill`-proven fill for a painted
    /// region. Insetting avoids JPEG ringing / anti-aliasing at the bar edges.
    /// Handles `.black` AND `.white` fill for free (no `FillColor` threading into
    /// the public API). Returns 0…1 RGB, or nil if the inset interior is
    /// degenerate. For an UNPAINTED region (a paint miss) the interior is not fill,
    /// so calibration is "wrong" — but readable ink there has high dynamic range
    /// (a strong outlier vs whatever colour is calibrated), so the outlier floor
    /// keeps it regardless. `static` for direct unit testing.
    ///
    /// For a POLYGON region (`vertices` ≥ 3, normalized space) the rect
    /// interior is NOT all fill — a concave shape's inset bbox mixes fill with
    /// preserved page background, and the averaged "fill" then reads the bar's
    /// own pixels as contrast. The probe instead anchors at the polygon's area
    /// centroid and shrinks until it sits fully inside the polygon
    /// (`polygonCalibrationProbe`); when no interior rect emerges, fall back to
    /// the bbox inset — wrong calibration there stays fail-safe exactly as the
    /// paint-miss case above.
    static func calibrateFillColor(
        region: CGRect,
        vertices: [CGPoint]? = nil,
        rgba: UnsafePointer<UInt8>,
        width: Int,
        height: Int,
        bytesPerRow: Int
    ) -> (r: CGFloat, g: CGFloat, b: CGFloat)? {
        let probe: CGRect
        if let vertices, vertices.count >= 3,
           let polygonProbe = polygonCalibrationProbe(
               vertices: vertices, bbox: region,
               marginX: fillSampleInsetPixels / CGFloat(width),
               marginY: fillSampleInsetPixels / CGFloat(height)) {
            probe = polygonProbe
        } else {
            let inset = region.insetBy(dx: region.width * fillCalibrationInset,
                                       dy: region.height * fillCalibrationInset)
            probe = (inset.isNull || inset.isEmpty || inset.width <= 0 || inset.height <= 0) ? region : inset
        }
        let x0 = max(0, Int(probe.minX * CGFloat(width)))
        let x1 = min(width, Int(probe.maxX * CGFloat(width)))
        let y0 = max(0, Int((1 - probe.maxY) * CGFloat(height)))   // BL → top-down
        let y1 = min(height, Int((1 - probe.minY) * CGFloat(height)))
        guard x1 > x0, y1 > y0 else { return nil }
        var sr = 0.0, sg = 0.0, sb = 0.0, n = 0.0
        for y in y0..<y1 {
            let rowBase = y * bytesPerRow
            for x in x0..<x1 {
                let off = rowBase + x * 4
                sb += Double(rgba[off + 0]); sg += Double(rgba[off + 1]); sr += Double(rgba[off + 2])
                n += 1
            }
        }
        guard n > 0 else { return nil }
        return (CGFloat(sr / n / 255), CGFloat(sg / n / 255), CGFloat(sb / n / 255))
    }

    /// Probe rect for calibrating a POLYGON region's fill colour, in
    /// normalized space. Anchored at the polygon's area centroid, starting at
    /// the same interior share the rect probe uses (1 − 2·`fillCalibrationInset`
    /// per side of the bbox) and halving until the rect — grown by the ringing
    /// margin so the sampled pixels keep their distance from the polygon edges,
    /// mirroring `fillSampleInsetPixels` — sits fully inside the polygon.
    /// Returns nil when no interior rect emerges within four attempts (centroid
    /// outside a U-shape's interior, degenerate area): the caller then falls
    /// back to the bbox-inset probe, whose wrong calibration is fail-safe
    /// (outlier/recall floors keep readable ink regardless).
    static func polygonCalibrationProbe(
        vertices: [CGPoint],
        bbox: CGRect,
        marginX: CGFloat,
        marginY: CGFloat
    ) -> CGRect? {
        guard let centroid = polygonCentroid(vertices) else { return nil }
        var scale: CGFloat = 1 - 2 * fillCalibrationInset
        for _ in 0..<4 {
            let candidate = CGRect(
                x: centroid.x - bbox.width * scale / 2,
                y: centroid.y - bbox.height * scale / 2,
                width: bbox.width * scale,
                height: bbox.height * scale)
            let grown = candidate.insetBy(dx: -marginX, dy: -marginY)
            if rectFullyInsidePolygon(grown, vertices: vertices) {
                return candidate
            }
            scale /= 2
        }
        return nil
    }

    /// Part A: attach a per-box, full-RGB `BoxFillSample` to each hit, index-
    /// PARALLEL to `inRegionCandidateBoxes(of:)`. The page image is drawn once into
    /// a BGRA buffer; each region's fill colour is self-calibrated from its
    /// verifyFill-proven interior; the IN-REGION PORTION of every candidate box
    /// (box ∩ region-rect, Option A — 2026-06-28) is sampled against the fill of
    /// the region it overlaps most (by area). Only the
    /// single coordinate-trusted page image is sampled. On any failure the hits are
    /// returned unchanged (empty boxFill ⇒ the classifier excludes nothing). The
    /// buffer is zeroized on exit (SEC-5) so output pixels do not linger in heap.
    static func enrichWithFillSamples(
        _ hits: [OCRHit],
        image: CGImage,
        regions: [RedactionRegion]
    ) -> [OCRHit] {
        guard !hits.isEmpty, !regions.isEmpty else { return hits }
        let width = image.width, height = image.height
        guard width > 0, height > 0,
              let ctx = createBitmapContext(width: width, height: height) else { return hits }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = ctx.data else { return hits }
        defer { PixelOperations.zeroizeBitmapBuffer(ctx) }
        let rgba = data.assumingMemoryBound(to: UInt8.self)
        let bytesPerRow = ctx.bytesPerRow

        // Self-calibrate each region's fill colour once. A polygon
        // region's probe anchors inside the polygon (its bbox interior mixes
        // fill with preserved page background); the SAMPLE rect below stays
        // box ∩ region-rect — only the calibration probe moves (decision
        // pre-made 2026-07-05; Option A semantics unchanged).
        let calibrated: [(rect: CGRect, fill: (r: CGFloat, g: CGFloat, b: CGFloat))] =
            regions.compactMap { region in
                calibrateFillColor(region: region.normalizedRect, vertices: region.vertices,
                                   rgba: rgba,
                                   width: width, height: height, bytesPerRow: bytesPerRow)
                    .map { (region.normalizedRect, $0) }
            }
        guard !calibrated.isEmpty else { return hits }

        return hits.map { hit in
            let boxes = inRegionCandidateBoxes(of: hit)
            let samples = boxes.map { box -> BoxFillSample in
                // Pick the region this box overlaps most (by area); both its fill
                // colour AND its rect drive the in-region-portion sample below. A box
                // overlapping no region is never in-region, so its sample is never
                // consulted for demotion; emit a definitely-ink sentinel anyway.
                var best: (rect: CGRect, fill: (r: CGFloat, g: CGFloat, b: CGFloat))?
                var bestArea: CGFloat = 0
                for c in calibrated {
                    let inter = box.intersection(c.rect)
                    let area = inter.isNull ? 0 : inter.width * inter.height
                    if area > bestArea { bestArea = area; best = c }
                }
                guard let chosen = best else {
                    return BoxFillSample(fillFraction: 0, contrastFraction: 1, maxDeviation: 1)
                }
                // OPTION A (Jesse-approved 2026-06-28): decide fill-consistency on the
                // verifyFill-proven IN-REGION portion (box ∩ region-rect), NOT the whole
                // box. On-device measurement (iOS 26.4) falsified the original whole-box
                // assumption — Vision's hallucination boxes STRADDLE the bar edge into
                // the white page background (whole-box fill+contrast = 1.000, every box
                // maxDeviation = 1.000 off a pure-white pixel), so a whole-box sample
                // reads that white sliver as contrast/outlier and the strict floors
                // refuse to demote the false positives. Clipping to the in-region portion
                // drops the out-of-rect sliver, so the solid bar demotes cleanly under
                // the ORIGINAL floors (no threshold loosening). The classifier still uses
                // the WHOLE box for the in-region COVERAGE decision; only this fill SAMPLE
                // is clipped. Residual: a contrived edge-straddle LEAK demotes to WARN,
                // never a clean PASS — the precision-only bar holds (S3 may route the
                // out-of-rect portion to the out-of-region WARN).
                let raw = box.intersection(chosen.rect)
                guard !raw.isNull, !raw.isEmpty else {
                    return BoxFillSample(fillFraction: 0, contrastFraction: 1, maxDeviation: 1)
                }
                // Trim a fixed pixel margin so JPEG ringing at the rect↔bar boundary
                // does not spike maxDeviation and block demotion (see
                // `fillSampleInsetPixels`). Fall back to the un-inset in-region rect
                // if the inset would collapse a very thin box (then `boxFillSample`'s
                // own degenerate guard yields the definitely-ink sentinel — safe).
                let inset = raw.insetBy(dx: fillSampleInsetPixels / CGFloat(width),
                                        dy: fillSampleInsetPixels / CGFloat(height))
                let sampleRect = (inset.isNull || inset.isEmpty
                                  || inset.width <= 0 || inset.height <= 0) ? raw : inset
                return boxFillSample(box: sampleRect, rgba: rgba, width: width,
                                     height: height, bytesPerRow: bytesPerRow, fill: chosen.fill)
            }
            return OCRHit(box: hit.box, wordBoxes: hit.wordBoxes, text: hit.text,
                          confidence: hit.confidence, boxFill: samples)
        }
    }

    /// Per-word normalized boxes for a recognized line (ADV-2 A2-3), mirroring
    /// `DetectionOrchestrator.extractWordBounds` (`.byWords` + `boundingBox(for:)`).
    /// Returns `[]` when no word box is obtainable — the caller then falls back
    /// to the conservative line-level box.
    private static func wordBoxes(from candidate: VNRecognizedText) -> [CGRect] {
        let text = candidate.string
        let ns = text as NSString
        var boxes: [CGRect] = []
        ns.enumerateSubstrings(
            in: NSRange(location: 0, length: ns.length), options: .byWords
        ) { _, wordNSRange, _, _ in
            guard let range = Range(wordNSRange, in: text),
                  let boxObs = try? candidate.boundingBox(for: range) else { return }
            boxes.append(boxObs.boundingBox)
        }
        return boxes
    }

    /// Which Layer-2 page list a page's OCR outcome folds into. The
    /// bounded task group returns one of these per page; the fold then builds the
    /// SORTED page lists the priority verdict reads. `.clean` contributes to no
    /// list (images OCR'd, nothing to report).
    enum PageOCRBucket: Sendable, Equatable {
        case sensitiveTermInRegion
        // Split per page mode: a readable in-region hit on a rasterized page is
        // a leak regardless of term match (the region holds no readable text by
        // construction — D08-F2), even when the DOCUMENT ran in Searchable mode
        // and only this page fell back to rasterization. The fold FAILs the
        // secure-raster list and keeps the Searchable list on the existing WARN.
        case textInRegionSecureRaster
        case textInRegionSearchable
        case fillArtifactInRegion
        case sensitiveTermOutsideRegion
        case textOutsideRegionsOnly
        case unmappable
        case unchecked
        case clean
    }

    /// One page's folded Layer-2 outcome. A named tuple type so the task group's
    /// `of:` argument and the accumulator stay unambiguous.
    typealias PageOutcome = (page: Int, bucket: PageOCRBucket)

    /// One page's already-downsampled OCR inputs, captured by value
    /// so the bounded task group OCRs pages concurrently without sharing the
    /// `PDFDocument`. `@unchecked Sendable`: `CGImage` is an immutable Core
    /// Graphics value and `RedactionRegion` is already Sendable; the wrapper makes
    /// the by-value hand-off explicit (house pattern — SendablePDFPage /
    /// PDFPageData).
    private struct PageOCRWork: @unchecked Sendable {
        let page: Int                       // 1-based, for messages
        let images: [CGImage]               // already downsampled to the OCR cap
        let coordinatesTrusted: Bool
        let pageRegions: [RedactionRegion]
        // The mode THIS page was actually produced in. On a Searchable-mode run
        // the coordinator records fallback-rasterized pages as
        // .secureRasterization in perPageModes; Layer 2 is the only layer that
        // can see pixels on those pages, so its verdict must follow the page's
        // mode, not the document's.
        let effectiveMode: PipelineMode
    }

    /// S3 (Part A rider): the verifier's one Vision seam. `VNImageRequestHandler
    /// .perform()` is synchronous and dispatches internally onto a
    /// capacity-controlled Vision queue; called from cooperative-pool threads
    /// (the Layer-2 task group below) it BLOCKS those threads inside Vision's
    /// sync gate. Stack several concurrent `runLayer2OCR` callers (e.g. a
    /// parallel test suite) and the pool exhausts — the process deadlocks
    /// (reproduced 3× solo on the iOS 26.4 sim, identical stacks:
    /// VNControlledCapacityTasksQueue sync-dispatch). Routing every verifier
    /// perform through ONE serial, off-pool queue frees the cooperative threads
    /// (they await a continuation instead of blocking) and Vision sees at most
    /// one verifier request at a time. Page extraction and classification still
    /// overlap under the task group; Vision parallelizes internally within a
    /// request. (F2-8 precedent in `DetectionOrchestrator.runOCR` — acceptable
    /// there because detection's page loop is sequential; the Layer-2 group is
    /// not.) The queue declares NO QoS of its own: each block runs at the
    /// submitting task's propagated QoS, matching the pre-queue semantics where
    /// perform() ran on the caller's thread — an explicit elevation here would
    /// preempt sibling default-QoS work under load.
    private static let visionPerformQueue = DispatchQueue(
        label: "com.resecta.RedactionEngine.verification.layer2-vision")

    /// CGImage hand-off into the Vision-queue closure (house pattern —
    /// `PageOCRWork`): an immutable Core Graphics value crossing an explicit
    /// by-value boundary.
    private struct Layer2ImageBox: @unchecked Sendable { let image: CGImage }

    /// Guard seam for the Vision perform error path (no fixture
    /// can make `VNImageRequestHandler.perform` throw deterministically).
    /// Production-inert: nil outside tests. When set, an image the closure
    /// flags takes the same nil return the real perform error takes.
    nonisolated(unsafe) static var onLayer2OCRSimulateError: (@Sendable (CGImage) -> Bool)?

    /// One image's Layer-2 OCR pass on the dedicated Vision queue: build the
    /// frozen `verificationLayer2` request, perform it, and map the observations
    /// to `OCRHit`s (Sendable) before resuming the awaiting task. A perform
    /// error returns nil — "could not check" — which the caller folds into the
    /// page's `.unchecked` WARN; it must never read as "checked, found nothing"
    /// (the prior [] return made an OCR error indistinguishable from a clean
    /// page and contributed to PASS).
    private static func layer2OCRHits(in image: CGImage) async -> [OCRHit]? {
        if let simulateError = onLayer2OCRSimulateError, simulateError(image) {
            return nil
        }
        let boxed = Layer2ImageBox(image: image)
        return await withCheckedContinuation { continuation in
            visionPerformQueue.async {
                let request = OCRConfiguration.verificationLayer2.makeRequest()
                let handler = VNImageRequestHandler(cgImage: boxed.image)
                do {
                    try handler.perform([request])
                } catch {  // LegalPhrases:safe — OCR error handling, not a promise
                    continuation.resume(returning: nil)
                    return
                }
                let observations = request.results ?? []
                continuation.resume(returning: observations.compactMap { obs in
                    guard obs.confidence >= Self.ocrConfidenceThreshold else { return nil }
                    let candidate = obs.topCandidates(1).first
                    return OCRHit(
                        box: obs.boundingBox,
                        wordBoxes: candidate.map(Self.wordBoxes(from:)) ?? [],
                        text: candidate?.string,
                        confidence: obs.confidence
                    )
                })
            }
        }
    }

    /// OCR every (already-downsampled) image on one page and fold the
    /// result into a single Layer-2 bucket. No PDFKit — so the bounded task group
    /// runs pages concurrently. Mirrors the per-page body of the original
    /// sequential loop exactly; only the dispatch shape changed. The Vision
    /// perform itself hops to the serial `visionPerformQueue` (S3 rider — see
    /// `layer2OCRHits`) so no cooperative-pool thread blocks inside Vision.
    private static func classifyPageImages(
        _ work: PageOCRWork,
        sensitiveTerms: [SensitiveTerm]
    ) async throws -> PageOutcome {
        // Run OCR on EVERY image with the FROZEN verificationLayer2 preset
        // (.fast, no language correction) at the moderate confidence threshold
        // (ENGINE §6.2) — 0.50 reduces bitmap-artifact noise while detecting
        // leaked text; Layers 1 and 3 give independent coverage. The S8 OCR
        // program must not retune the verifier. An OCR error on ANY of the
        // page's images means the page was not fully checked — fold it into the
        // `.unchecked` WARN rather than letting the missing image read as clean.
        var hits: [OCRHit] = []
        for pageImage in work.images {
            try Task.checkCancellation()
            guard let imageHits = await Self.layer2OCRHits(in: pageImage) else {
                return (work.page, .unchecked)
            }
            hits.append(contentsOf: imageHits)
        }

        if work.coordinatesTrusted {
            // Part A: enrich the hits with in-region-portion, full-RGB fill samples so the
            // classifier can tell a fill artifact (Vision reading tokens off the
            // SOLID bar) from readable in-region ink. coordinatesTrusted ⇒ a single
            // full-page image, so sample that one image.
            let enriched = work.images.first.map {
                Self.enrichWithFillSamples(hits, image: $0, regions: work.pageRegions)
            } ?? hits
            switch Self.classifyPageOCR(
                hits: enriched, pageRegions: work.pageRegions, sensitiveTerms: sensitiveTerms
            ) {
            case .sensitiveTermInRegion: return (work.page, .sensitiveTermInRegion)
            case .textInRegion:
                // Bucketed by the PAGE's mode: a rasterized page's region holds
                // no readable text by construction, so an in-region hit there is
                // a leak (folds to FAIL) even when the document mode is
                // Searchable and only this page fell back.
                return (work.page, work.effectiveMode == .secureRasterization
                    ? .textInRegionSecureRaster : .textInRegionSearchable)
            case .fillArtifactInRegion:
                // Vision hallucinated tokens out of the solid fill itself — no
                // readable ink (full-RGB fill-consistent on the in-region portion).
                // The classification applies on BOTH page modes: a painted fill
                // bar is the same pixels either way, so a proven fill artifact
                // folds to the informational note regardless of the page's mode.
                // A non-proven in-region hit on a Searchable page keeps the
                // textInRegion WARN path above.
                return (work.page, .fillArtifactInRegion)
            case .sensitiveTermOutsideRegions:
                // Only rasterized pages surface the dedicated term-outside WARN:
                // there is no text layer, so OCR is the only reader that can
                // notice a redacted term surviving elsewhere on the page. A
                // Searchable page's text layer is owned by Layers 3/10 — keep
                // the generic outside-regions path there (unchanged behavior).
                return (work.page, work.effectiveMode == .secureRasterization
                    ? .sensitiveTermOutsideRegion : .textOutsideRegionsOnly)
            case .textOutsideRegionsOnly: return (work.page, .textOutsideRegionsOnly)
            case .none:                  return (work.page, .clean)
            }
        } else if !work.pageRegions.isEmpty,
                  hits.contains(where: { !($0.text ?? "").isEmpty }) {
            // Unmappable coordinates with a redaction region present: text might
            // sit inside a region but cannot be confirmed. Conservative WARN
            // (C-B contract: never identity-map unmappable observations).
            return (work.page, .unmappable)
        } else if work.effectiveMode == .searchableRedaction,
                  hits.contains(where: { !($0.text ?? "").isEmpty }) {
            // No regions to violate — selectable text on a Searchable page is
            // expected; keep the INFO continuity.
            return (work.page, .textOutsideRegionsOnly)
        }
        return (work.page, .clean)
    }

    /// Returns (status, affectedPages): the winning fold bucket's page list,
    /// 0-based for the UI's tappable page chips (the message text keeps its
    /// 1-based numbering). A clean PASS carries nil.
    private func runLayer2OCR(
        _ doc: PDFDocument,
        pipelineMode: PipelineMode,
        regions: [Int: [RedactionRegion]],
        sensitiveTerms: [SensitiveTerm],
        perPageModes: [PipelineMode]
    ) async throws -> (VerificationStatus, [Int]?) {
        // PERF-8 / CANCEL-001: entry-level cooperative cancellation, plus a
        // per-page check inside the OCR loop. A 50-page OCR pass that does
        // not check until layer return would exceed the 50 ms p95
        // cancel→surrender budget by ~180×.
        try Task.checkCancellation()

        // Does ANY page carry a redaction region? The out-of-region fold below
        // uses this to tell a rasterized document that HAD regions (surviving
        // out-of-region content is noted as INFO) from one with none (the
        // raster's own content → PASS).
        let documentHasRegions = regions.values.contains { !$0.isEmpty }

        // The per-page OCR pass (extract → downsample → Vision →
        // classify) is the layer's dominant cost. Page extraction stays on this
        // task — PDFKit reads are kept single-threaded, since the parallel base
        // batch already gives each layer its own PDFDocument instance —
        // while the expensive Vision OCR runs in a width-bounded task group. Each
        // result carries its 1-based page number and folds into the same priority
        // buckets the sequential loop produced; the page lists are SORTED before
        // they reach any message, so the verdict is independent of completion
        // order. Pages are processed in chunks of `ocrParallelism` so at most that
        // many pages' images are resident at once (memory stays bounded on large
        // scanned documents — the whole point of this entry).
        let pageCount = doc.pageCount
        var pageOutcomes: [PageOutcome] = []
        pageOutcomes.reserveCapacity(pageCount)

        var pageIndex = 0
        while pageIndex < pageCount {
            try Task.checkCancellation()
            let chunkEnd = min(pageIndex + Self.ocrParallelism, pageCount)

            // Phase 1 — sequential extraction on this task. A page with no
            // extractable image is bucketed `.unchecked` here and never enters the
            // OCR group. VQ-23: a page PDFKit cannot open (or with no CGPDFPage
            // backing) is bucketed `.unchecked` too — it was never OCR-checked,
            // and the prior silent `continue` let it read as clean.
            var chunkWork: [PageOCRWork] = []
            for i in pageIndex..<chunkEnd {
                try Task.checkCancellation()
                guard let page = doc.page(at: i),
                      let cgPage = page.pageRef else {
                    pageOutcomes.append((i + 1, .unchecked))
                    continue
                }

                // Gather ALL embedded JPEG/JPEG2000 images on the page
                // (was: the first only — additional images went unverified).
                // Any image whose bounded decode produced no CGImage
                // (over-cap or corrupt data) means this page was not fully
                // checked — `.unchecked`, mirroring the OCR-error path in
                // `classifyPageImages`.
                let extraction = Self.extractPageImages(from: cgPage)
                guard extraction.failedDecodeCount == 0 else {
                    pageOutcomes.append((i + 1, .unchecked))
                    continue
                }
                var images = extraction.images

                // Identity contract (C-B binding §3 / ADV-2 A2-1): Vision's
                // normalized observation coordinates equal page-normalized
                // coordinates ONLY for a single full-page image. With multiple
                // image XObjects, per-image Vision space does not map to page space.
                var coordinatesTrusted = images.count == 1

                if images.isEmpty {
                    // Non-JPEG pages (CCITT / JBIG2 / Flate /
                    // inline-only XObjects) get a PDFPage.thumbnail fallback before
                    // joining uncheckedPages. Request the DISPLAYED (effective)
                    // aspect — dims swapped for 90°/270° rotation — and trust the
                    // observation coordinates only when the returned render is
                    // unpadded at that aspect; a letterboxed thumbnail shifts
                    // Vision-normalized coords off page-normalized space.
                    let raw = page.bounds(for: .cropBox).size
                    let r = ((page.rotation % 360) + 360) % 360
                    let displayedSize = (r == 90 || r == 270)
                        ? CGSize(width: raw.height, height: raw.width) : raw
                    #if canImport(UIKit)
                    if displayedSize.width > 0, displayedSize.height > 0,
                       let thumb = page.thumbnail(of: displayedSize, for: .cropBox).cgImage {
                        images = [thumb]
                        coordinatesTrusted = Self.aspectMatches(
                            CGSize(width: thumb.width, height: thumb.height),
                            displayedSize)
                    }
                    #else
                    // macOS tooling destination: thumbnail returns NSImage.
                    if displayedSize.width > 0, displayedSize.height > 0,
                       let thumb = page.thumbnail(of: displayedSize, for: .cropBox)
                        .cgImage(forProposedRect: nil, context: nil, hints: nil) {
                        images = [thumb]
                        coordinatesTrusted = Self.aspectMatches(
                            CGSize(width: thumb.width, height: thumb.height),
                            displayedSize)
                    }
                    #endif
                }

                guard !images.isEmpty else {
                    pageOutcomes.append((i + 1, .unchecked))
                    continue
                }

                // Downsample to the OCR pixel cap before Vision. The
                // normalized observation coordinates are scale-invariant, so the
                // identity contract above is unaffected by the resize.
                let ocrImages = images.map(Self.downsampleForOCR)

                // ADV-2 A2-4: scope against the SAME region set the fill path used.
                let pageRegions = Self.layer2RegionSnapshot(regions[i] ?? [])
                chunkWork.append(PageOCRWork(
                    page: i + 1,
                    images: ocrImages,
                    coordinatesTrusted: coordinatesTrusted,
                    pageRegions: pageRegions,
                    effectiveMode: i < perPageModes.count ? perPageModes[i] : pipelineMode))
            }

            // Phase 2 — bounded-concurrent OCR + classify (width ≤ ocrParallelism).
            if !chunkWork.isEmpty {
                let chunkResults = try await withThrowingTaskGroup(
                    of: PageOutcome.self
                ) { group in
                    for work in chunkWork {
                        group.addTask {
                            // PERF-8: per-page cooperative cancellation inside the
                            // group body — the discipline the sequential loop kept
                            // at the top of each iteration now lives here.
                            try Task.checkCancellation()
                            return try await Self.classifyPageImages(
                                work,
                                sensitiveTerms: sensitiveTerms)
                        }
                    }
                    var acc: [PageOutcome] = []
                    for try await outcome in group { acc.append(outcome) }
                    return acc
                }
                pageOutcomes.append(contentsOf: chunkResults)
            }

            pageIndex = chunkEnd
        }

        return Self.foldLayer2PageOutcomes(
            pageOutcomes,
            pipelineMode: pipelineMode,
            documentHasRegions: documentHasRegions)
    }

    /// Cross-page fold: collapses the per-page Layer-2 buckets into the layer's
    /// single (status, pageReferences) verdict. `static` and OCR-free so arm
    /// precedence has a direct unit test (`Layer2FoldOrderTests`);
    /// `runLayer2OCR` feeds it the real buckets.
    static func foldLayer2PageOutcomes(
        _ pageOutcomes: [PageOutcome],
        pipelineMode: PipelineMode,
        documentHasRegions: Bool
    ) -> (VerificationStatus, [Int]?) {
        // Fold the per-page buckets into the per-bucket page lists, SORTED
        // ascending so the message text is byte-identical regardless of OCR
        // completion order (the sequential loop appended in page order; the
        // sort restores that invariant under the task group). The
        // identity contract: pages whose OCR images cannot be
        // coordinate-mapped to page space are surfaced as a conservative WARN,
        // never identity-mapped.
        func pages(in bucket: PageOCRBucket) -> [Int] {
            pageOutcomes.filter { $0.bucket == bucket }.map(\.page).sorted()
        }
        let pagesWithSensitiveTermInRegion = pages(in: .sensitiveTermInRegion)
        let pagesWithTextInRegionSecureRaster = pages(in: .textInRegionSecureRaster)
        let pagesWithTextInRegionSearchable = pages(in: .textInRegionSearchable)
        let pagesWithFillArtifactInRegion = pages(in: .fillArtifactInRegion)
        let pagesWithSensitiveTermOutsideRegion = pages(in: .sensitiveTermOutsideRegion)
        let pagesWithTextOutsideRegionsOnly = pages(in: .textOutsideRegionsOnly)
        let pagesWithUnmappableImages = pages(in: .unmappable)
        let uncheckedPages = pages(in: .unchecked)

        // ARCH §12.2: page numbers only, never document content, in any message.
        // Priority fold: FAIL (term in region) > FAIL/WARN (text in region, by
        // the page's own mode) > WARN (sensitive term outside regions,
        // rasterized pages) > WARN (unmappable) > INFO (Part A fill artifact
        // in region) > INFO (text only outside regions) > unchecked WARN >
        // PASS. The layer reports its single most specific outcome, with the
        // two warnable out-of-region arms ahead of the proven-artifact note —
        // on a multi-signal document a page in a warnable bucket sets the
        // masthead, not the note. Within the note tier the order stays
        // specificity (fill artifact > generic outside text); the unchecked
        // arm keeps its long-standing position below the expected-state notes.
        if !pagesWithSensitiveTermInRegion.isEmpty {
            let list = pagesWithSensitiveTermInRegion.map(String.init).joined(separator: ", ")
            // An OCR hit inside a redacted region means readable text inside the
            // black box — a leak in EITHER mode. Region scoping already
            // excludes Searchable Redaction's expected surviving text.
            return (.fail("Sensitive text detected within a redacted region on \(pagePhrase(pagesWithSensitiveTermInRegion, list: list))"),
                    pagesWithSensitiveTermInRegion.map { $0 - 1 })
        }
        // D08-F2: on a rasterized page the region is a destroyed-pixel box that
        // holds NO readable text by construction, so ANY in-region OCR hit is a
        // leak regardless of term match — FAIL. Keyed to the PAGE's mode (not
        // the document's): a Searchable-mode run's fallback-rasterized page has
        // the same no-readable-text construction, and Layer 2 is the only layer
        // that inspects its pixels. Searchable pages retain a glyph layer behind
        // the fill, so a non-term in-region hit there stays the existing WARN
        // (term hits already FAILed above via .sensitiveTermInRegion).
        if !pagesWithTextInRegionSecureRaster.isEmpty {
            let list = pagesWithTextInRegionSecureRaster.map(String.init).joined(separator: ", ")
            return (.fail("Readable text detected within a redacted region on \(pagePhrase(pagesWithTextInRegionSecureRaster, list: list))"),
                    pagesWithTextInRegionSecureRaster.map { $0 - 1 })
        }
        if !pagesWithTextInRegionSearchable.isEmpty {
            let list = pagesWithTextInRegionSearchable.map(String.init).joined(separator: ", ")
            return (.warn("OCR detected text within a redacted region on \(pagePhrase(pagesWithTextInRegionSearchable, list: list))"),
                    pagesWithTextInRegionSearchable.map { $0 - 1 })
        }
        // A sensitive term the user redacted is still readable OUTSIDE every
        // region on a rasterized page (e.g. a displaced fill) — the one signature
        // only OCR can notice there, and until now indistinguishable from the
        // generic out-of-region arm below. A WARN rather than a FAIL: a term can
        // legitimately remain readable when the user chose to leave an
        // occurrence unredacted.
        if !pagesWithSensitiveTermOutsideRegion.isEmpty {
            let list = pagesWithSensitiveTermOutsideRegion.map(String.init).joined(separator: ", ")
            return (.warn("A sensitive term is readable outside every redacted region on \(pagePhrase(pagesWithSensitiveTermOutsideRegion, list: list)) — review those pages before sharing."),
                    pagesWithSensitiveTermOutsideRegion.map { $0 - 1 })
        }
        // Unmappable-coordinate pages (multi-image or padded thumbnail)
        // that carry OCR text near a region — surfaced as a WARN because the
        // identity check that would FAIL/PASS them is unsound.
        if !pagesWithUnmappableImages.isEmpty {
            let list = pagesWithUnmappableImages.map(String.init).joined(separator: ", ")
            return (.warn("OCR coordinates could not be mapped to page space on \(pagePhrase(pagesWithUnmappableImages, list: list)) — text could not be confirmed inside or outside a redacted region"),
                    pagesWithUnmappableImages.map { $0 - 1 })
        }
        if !pagesWithFillArtifactInRegion.isEmpty {
            let list = pagesWithFillArtifactInRegion.map(String.init).joined(separator: ", ")
            // Part A: Vision hallucinated tokens out of the SOLID redaction fill
            // itself — every in-region box was full-RGB fill-consistent on its in-region portion,
            // so no readable text was recovered. Demote-never-silence: an
            // informational note, never a FAIL (a real in-region leak carries
            // readable contrast → it is classified textInRegion above, not
            // here). Reached on both page modes — a proven fill artifact reads
            // the same off a Searchable page's painted bar as off a
            // secure-raster one. Returns below the warnable out-of-region arms
            // — on a multi-signal document the warning sets the layer status —
            // and above the generic outside-text note (note-tier specificity).
            return (.info("OCR detected likely fill artifacts within a redacted region on \(pagePhrase(pagesWithFillArtifactInRegion, list: list)) — no readable text recovered"),
                    pagesWithFillArtifactInRegion.map { $0 - 1 })
        }
        if !pagesWithTextOutsideRegionsOnly.isEmpty {
            let list = pagesWithTextOutsideRegionsOnly.map(String.init).joined(separator: ", ")
            switch pipelineMode {
            case .searchableRedaction:
                // Selectable/raster text outside regions is expected on a Searchable page.
                return (.info("OCR detected text on \(pagePhrase(pagesWithTextOutsideRegionsOnly, list: list)) — expected for Searchable Redaction mode."),
                        pagesWithTextOutsideRegionsOnly.map { $0 - 1 })
            case .secureRasterization:
                // Out-of-region OCR text on a Secure-Rasterized page is expected
                // output — nearly every real document keeps readable non-redacted
                // content, so as a WARN this arm fired on virtually every run and
                // pinned the masthead off green, drowning the conditional warns
                // (unmappable, unchecked, could-not-read) that DO carry signal.
                // The displaced-fill leak the D08-F1 WARN was aimed at is now
                // carried by the specific arms above: a redacted term surviving
                // out-of-region is the .sensitiveTermOutsideRegion WARN, and
                // in-region survivors FAIL. Expected-under-this-mode observations
                // are informational; every could-not-verify condition keeps its
                // warning tier. Pages with NO regions have nothing to violate →
                // the raster's own content → PASS.
                if documentHasRegions {
                    return (.info("Unredacted page content remains readable on \(pagePhrase(pagesWithTextOutsideRegionsOnly, list: list)) — expected for this mode."),
                            pagesWithTextOutsideRegionsOnly.map { $0 - 1 })
                }
            }
        }
        if !uncheckedPages.isEmpty {
            return (.warn("OCR could not be run on \(pageCountPhrase(uncheckedPages.count))"),
                    uncheckedPages.map { $0 - 1 })
        }
        return (.pass, nil)
    }

    /// Extract ALL embedded JPEG/JPEG2000 images from a PDF page's XObject
    /// streams. Returns every image, not just the first —
    /// a page can carry multiple image XObjects and each must be OCR-checked.
    ///
    /// VQ-32: each image decodes via `CGImageSourceCreateThumbnailAtIndex`
    /// bounded by the existing `ocrMaxPixelDimension` cap, so a pathological
    /// embedded image cannot force an unbounded full-size transient decode
    /// (the prior `CGImageSourceCreateImageAtIndex` deferred the full-size
    /// decode to `downsampleForOCR`'s `ctx.draw`). Vision-facing quality is
    /// unaffected: the check reads text, not pixel fidelity, and normalized
    /// observation coordinates are scale-invariant (same argument as
    /// `downsampleForOCR`; the detection path applies the same 4096-px
    /// policy). `failedDecodeCount` counts JPEG/JPEG2000 streams whose decode
    /// produced no image (corrupt or undecodable data) — the caller buckets
    /// such a page `.unchecked`, because a decode failure must never read as
    /// "checked, found nothing". The `page.thumbnail` fallback path in
    /// `runLayer2OCR` is already size-bounded by the page box and is
    /// unchanged. `static` so the multi-image guard test can call it directly
    /// (mirrors the classifyPageOCR / layer2RegionSnapshot testing seam).
    static func extractPageImages(
        from cgPage: CGPDFPage
    ) -> (images: [CGImage], failedDecodeCount: Int) {
        guard let dict = cgPage.dictionary else { return ([], 0) }
        var resources: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(dict, "Resources", &resources),
              let res = resources else { return ([], 0) }
        var xobjects: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(res, "XObject", &xobjects),
              let xobj = xobjects else { return ([], 0) }

        var images: [CGImage] = []
        var failedDecodeCount = 0
        CGPDFDictionaryApplyBlock(xobj, { _, value, _ in
            var stream: CGPDFStreamRef?
            guard CGPDFObjectGetValue(value, .stream, &stream),
                  let s = stream else { return true }

            var format = CGPDFDataFormat.raw
            guard let data = CGPDFStreamCopyData(s, &format) else { return true }

            if format == .jpegEncoded || format == .JPEG2000 {
                // kCGImageSourceCreateThumbnailFromImageAlways: decode from
                // the full image (never a low-res embedded EXIF thumbnail);
                // max-pixel-size makes that decode capped, not full-size.
                let options: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: ocrMaxPixelDimension,
                ]
                if let source = CGImageSourceCreateWithData(data, nil),
                   let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
                    images.append(image)  // was `return false` (first only)
                } else {
                    failedDecodeCount += 1  // page must not read as checked
                }
            }
            return true  // keep iterating across all images
        }, nil)

        return (images, failedDecodeCount)
    }

    /// Downsample a decoded page image so its largest dimension is at
    /// most `ocrMaxPixelDimension` before Vision OCR. The Layer-2 check looks for
    /// readable leaked text, not pixel fidelity. Images already
    /// within the cap are returned unchanged. A context-construction or render
    /// failure falls back to the original image — a larger image still OCRs
    /// correctly, only slower, so this is a best-effort speed step, never a
    /// correctness gate. `static` so a guard test can pin the cap directly
    /// (mirrors the extractPageImages / classifyPageOCR testing seam).
    static func downsampleForOCR(_ image: CGImage) -> CGImage {
        let longest = max(image.width, image.height)
        guard longest > ocrMaxPixelDimension else { return image }
        let scale = CGFloat(ocrMaxPixelDimension) / CGFloat(longest)
        let newW = max(1, Int((CGFloat(image.width) * scale).rounded()))
        let newH = max(1, Int((CGFloat(image.height) * scale).rounded()))
        guard let ctx = createBitmapContext(width: newW, height: newH) else { return image }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: newW, height: newH))
        return ctx.makeImage() ?? image
    }

    /// True when an image's pixel aspect ratio matches the requested page aspect
    /// within tolerance — i.e. a thumbnail render is unpadded (ADV-2 A2-9). A
    /// padded (letterboxed) thumbnail scales/shifts Vision-normalized
    /// coordinates off page-normalized space, so its observations must be
    /// treated conservatively rather than identity-mapped.
    static func aspectMatches(_ imageSize: CGSize, _ pageSize: CGSize) -> Bool {
        guard imageSize.width > 0, imageSize.height > 0,
              pageSize.width > 0, pageSize.height > 0 else { return false }
        let imageAspect = imageSize.width / imageSize.height
        let pageAspect = pageSize.width / pageSize.height
        return abs(imageAspect - pageAspect) / pageAspect <= 0.02
    }

    /// PDF token delimiters + whitespace (ISO 32000 §7.2.2–§7.2.3). A structural
    /// match whose following byte is one of these is a complete PDF token.
    static let pdfDelimiters: Set<UInt8> = [
        0x00, 0x09, 0x0A, 0x0C, 0x0D, 0x20,   // whitespace: NUL TAB LF FF CR SP
        0x28, 0x29, 0x3C, 0x3E, 0x5B, 0x5D,   // ( ) < > [ ]
        0x7B, 0x7D, 0x2F, 0x25,               // { } / %
    ]

    /// Raw (still-encoded) bytes of every JPEG XObject stream on a page. These
    /// carry the APP1/EXIF segments that PDFKit's page.string and the structural
    /// raw-byte pass do not surface (the bytes live inside the image stream).
    static func extractRawJPEGStreams(from cgPage: CGPDFPage) -> [Data] {
        guard let dict = cgPage.dictionary else { return [] }
        var resources: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(dict, "Resources", &resources),
              let res = resources else { return [] }
        var xobjects: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(res, "XObject", &xobjects),
              let xobj = xobjects else { return [] }
        var streams: [Data] = []
        CGPDFDictionaryApplyBlock(xobj, { _, value, _ in
            var stream: CGPDFStreamRef?
            guard CGPDFObjectGetValue(value, .stream, &stream),
                  let s = stream else { return true }
            var format = CGPDFDataFormat.raw
            guard let data = CGPDFStreamCopyData(s, &format) else { return true }
            if format == .jpegEncoded { streams.append(data as Data) }  // EXIF is JPEG-only
            return true
        }, nil)
        return streams
    }

    /// Scan a raw JPEG byte stream's APP1/EXIF segment(s) for any automaton
    /// match. Each `FF E1` segment is length-prefixed (2 big-endian bytes,
    /// INCLUDING the length field); a segment beginning with the `Exif\0\0`
    /// magic has its payload searched. Read-only and WARN-only — tolerant of
    /// multi-APP1 and truncated segments (worst case: a missed warn).
    static func jpegEXIFContainsTerm(_ jpeg: Data, automaton: AhoCorasick) -> Bool {
        let bytes = [UInt8](jpeg)
        let exifMagic: [UInt8] = [0x45, 0x78, 0x69, 0x66, 0x00, 0x00]  // "Exif\0\0"
        var i = 0
        while i + 4 <= bytes.count {
            guard bytes[i] == 0xFF, bytes[i + 1] == 0xE1 else { i += 1; continue }
            let segLen = (Int(bytes[i + 2]) << 8) | Int(bytes[i + 3])  // includes the 2 length bytes
            let payloadStart = i + 4
            let payloadEnd = min(i + 2 + segLen, bytes.count)          // clamp: truncated-safe
            guard payloadStart < payloadEnd else { i += 2; continue }
            let payload = bytes[payloadStart..<payloadEnd]
            if payload.starts(with: exifMagic),
               !automaton.search(Data(payload)).isEmpty {
                return true
            }
            i = payloadEnd
        }
        return false
    }

    // MARK: - Layer 3: Binary String Search (ENGINE §6.3)

    /// Returns (status, affectedPages, reviewTermTexts). The SVT-3
    /// decoded-page hits and the EXIF WARN carry their 0-based page lists
    /// for the UI's tappable page chips; the structural raw-byte pass is
    /// document-level (nil). The third element carries the display-only term
    /// texts behind an `.attention` verdict (nil for every other status).
    private func runLayer3BinarySearch(
        _ doc: PDFDocument, sensitiveTerms: [SensitiveTerm]
    ) throws -> (VerificationStatus, [Int]?, [String]?) {
        // PERF-8 / CANCEL-001: entry-level cooperative cancellation.
        try Task.checkCancellation()
        // No terms provided — expected for manual-only redaction. VQ-30:
        // INFO, not PASS — the string search did not run, and "No issues
        // found" would overstate what this layer observed. INFO lands in the
        // notes group without bumping the masthead (Layer-7 boundary-count
        // precedent).
        guard !sensitiveTerms.isEmpty else {
            return (.info("No sensitive terms were provided — string search did not run."), nil, nil)
        }
        // Filter terms too short to search (ENGINE §6.3, shared
        // `AhoCorasick.isSearchableTerm`): ≥3 scalars (supports 3-letter PII
        // abbreviations like SSN, DOB, PHI) or a 2-character CJK name.
        let validTerms = sensitiveTerms.filter { AhoCorasick.isSearchableTerm($0.text) }
        guard !validTerms.isEmpty else {
            return (.warn("All sensitive terms shorter than 3 characters"), nil, nil)
        }
        // Surfaced on the otherwise-clean path below so a partial drop is
        // never silent (the all-short WARN above covers the total drop).
        let droppedTermCount = sensitiveTerms.count - validTerms.count

        // Build the Aho-Corasick automaton with all encoding variants, keeping
        // each pattern's token-boundary discipline (PD-3) for the match
        // post-filters below.
        // DEFERRED: automaton caching is deferred to
        // V1.1. AhoCorasick is a Sendable value built fresh per
        // verification call; caching needs an actor/class wrapper for ~25 ms
        // saved once per export — low benefit, no security relevance.
        let termAutomaton = SensitiveTermAutomaton(validTerms: validTerms)
        guard termAutomaton.hasPatterns else { return (.pass, nil, nil) }
        let automaton = termAutomaton.automaton

        // ENGINE §6.3a: If the automaton degraded due to pattern size limits,
        // report the limitation rather than silently passing.
        if automaton.isDegraded {
            return (.warn("Sensitive term search exceeded size limit — results may be incomplete"), nil, nil)
        }

        // Get raw PDF bytes.
        // ENGINE §6.3 specifies memory-mapped access via
        // `Data(contentsOf:options:.mappedIfSafe)`; loadPDFData uses the
        // default-options overload, which is `.mappedIfSafe`.
        guard let (data, cgDoc) = loadPDFData(doc) else {
            return (.warn("Could not read output PDF for binary search"), nil, nil)
        }

        // First WARN encountered, returned only if no FAIL is found below: a
        // non-boundary structural fragment (Part A) or an EXIF hit (Part B) must
        // not mask a boundary-token or SVT-3 FAIL. Carries the 0-based page
        // list when the WARN is page-scoped (EXIF); nil when document-level.
        var deferredWarn: (message: String, pages: [Int]?)?
        // Structural complete-token FAIL, held (not returned) so the SVT-3
        // decoded pass below always runs — a structural hit must not mask a
        // decoded-text hit; both findings combine into one result at the end.
        var structuralFailMessage: String?

        // Structural pass: raw-byte scan with stream ranges excluded.
        // Compressed streams (FlateDecode) contain random byte sequences that
        // produce false positive matches. Structural/metadata bytes outside
        // streams are the meaningful search surface. Other layers (1, 2, 6, 8)
        // independently verify text content. See ISO 32000-2 §7.3.8.
        // DEFERRED: stream decompression (decompress-then-search)
        // is deferred to V1.1 — Resecta's own CGPDFContext
        // output embeds no compressed PII-bearing streams, and the SVT-3
        // page.string re-scan below compensates for PDFKit-decoded text.
        // Boundary-required terms (PD-3) drop matches embedded in an
        // alphanumeric run before any classification.
        let allMatches = termAutomaton.tokenFilteredMatches(in: data)
        if !allMatches.isEmpty {
            let streamRanges = findStreamRanges(data)
            let structuralMatches = allMatches.filter { match in
                !streamRanges.contains { $0.contains(match.position) }
            }
            if !structuralMatches.isEmpty {
                // Token-boundary rule ("verify matches are complete PDF
                // tokens"): a match bounded by PDF delimiters on BOTH sides is a
                // complete token → FAIL; a match embedded mid-token on either
                // side (the term inside "classifieddata", or trailing a name
                // token as in "/FontName ") is a possible fragment collision →
                // WARN. A match at buffer start / ending at EOF has no adjacent
                // byte on that side and counts as bounded there.
                let boundaryMatches = structuralMatches.filter { match in
                    if match.position > 0,
                       !Self.pdfDelimiters.contains(data[data.startIndex + match.position - 1]) {
                        return false
                    }
                    let end = match.position + match.length
                    guard end < data.count else { return true }  // EOF = boundary
                    return Self.pdfDelimiters.contains(data[data.startIndex + end])
                }
                if !boundaryMatches.isEmpty {
                    // Physical-occurrence count: unique (position, length), so
                    // one occurrence never multi-counts across case/encoding
                    // pattern variants.
                    structuralFailMessage =
                        "Sensitive string found in output PDF structural data (\(AhoCorasick.uniqueOccurrenceCount(boundaryMatches)) match(es))"
                } else {
                    deferredWarn = deferredWarn
                        ?? (message: "Possible sensitive term fragment in output PDF structural data (\(AhoCorasick.uniqueOccurrenceCount(structuralMatches)) match(es))",
                            pages: nil)
                }
            }
        }

        // ENGINE §6.3 SVT-3 (M1 tightening): always re-scan PDFKit's decoded
        // page.string, even when the structural raw-byte pass produced no
        // matches. PDFKit decodes operator-level encodings transparently
        // (UTF-16 surrogate halves, octal escapes inside literal strings,
        // Name-object substitution); sensitive terms that live only inside
        // an excluded stream range or behind a decoding transformation
        // surface here. See plan §4.1.
        // Accumulate across ALL pages (not first-hit-return) so a multi-page
        // leak is reported in one run; the 0-based page list feeds the chips.
        var decodedHitPages: [Int] = []
        var decodedMatchCount = 0
        var decodedTermTexts: [String] = []
        var decodedTermsSeen = Set<String>()
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i),
                  let pageText = page.string,
                  !pageText.isEmpty else { continue }
            let decoded = Data(pageText.utf8)
            let decodedMatches = termAutomaton.tokenFilteredMatches(in: decoded)
            if !decodedMatches.isEmpty {
                decodedHitPages.append(i)
                decodedMatchCount += AhoCorasick.uniqueOccurrenceCount(decodedMatches)
                for text in termAutomaton.matchedTermTexts(decodedMatches)
                where decodedTermsSeen.insert(text).inserted {
                    decodedTermTexts.append(text)
                }
            }
        }
        var decodedResidualMessage: String?
        if !decodedHitPages.isEmpty {
            let list = decodedHitPages.map { String($0 + 1) }.joined(separator: ", ")
            decodedResidualMessage =
                "Text matching your redactions is still readable on \(pagePhrase(decodedHitPages, list: list)) "
                + "(\(decodedMatchCount) instance\(decodedMatchCount == 1 ? "" : "s"))"
        }
        // Combine the held structural and decoded verdicts into ONE result so
        // neither verdict masks the other; the page list carries the decoded
        // pass's page-scoped part (the structural pass is document-level).
        // Tiering: a structural hit is a defect in the output itself → FAIL
        // (the decoded text rides along in the combined message). A decoded
        // hit alone is residual text OUTSIDE every region — the user's remedy
        // is a text search — → ATTENTION, with the term texts threaded for
        // display (the message itself stays content-free, ARCH §12.2).
        if let structuralFailMessage {
            let message = [structuralFailMessage, decodedResidualMessage]
                .compactMap { $0 }
                .joined(separator: "; ")
            return (.fail(message), decodedHitPages.isEmpty ? nil : decodedHitPages, nil)
        }
        if let decodedResidualMessage {
            return (.attention(decodedResidualMessage), decodedHitPages, decodedTermTexts)
        }

        // EXIF scan ("scan JPEG APP1/EXIF markers", WARN-only):
        // EXIF IFD bytes live inside the image stream and surface in neither
        // page.string nor the structural pass. Scan each JPEG XObject's raw
        // bytes for an APP1/EXIF segment carrying a sensitive term. WARN only;
        // skipped if a structural fragment WARN was already recorded.
        if deferredWarn == nil {
            for pageIdx in 1...max(1, cgDoc.numberOfPages) {
                try Task.checkCancellation()
                guard let cgPage = cgDoc.page(at: pageIdx) else { continue }
                if Self.extractRawJPEGStreams(from: cgPage).contains(where: {
                    Self.jpegEXIFContainsTerm($0, automaton: automaton)
                }) {
                    deferredWarn = (message: "Sensitive term found in embedded JPEG EXIF metadata on page \(pageIdx)",
                                    pages: [pageIdx - 1])
                    break
                }
            }
        }

        if let warn = deferredWarn { return (.warn(warn.message), warn.pages, nil) }
        if droppedTermCount > 0 {
            // Partial-coverage honesty: some (not all) terms were too short
            // to search. Informational — the searched terms were clean.
            return (.info(shortTermTail(droppedTermCount)), nil, nil)
        }
        return (.pass, nil, nil)
    }

    /// Byte ranges of PDF stream data (between `stream` and `endstream` markers).
    /// ISO 32000-2 §7.3.8: the `stream` keyword is followed by CR LF or LF
    /// (bare CR is not permitted), data bytes, then EOL + `endstream`.
    /// Returns ranges covering the data bytes (exclusive of markers).
    ///
    /// The strict pass REQUIRES that keyword EOL. Without it, any structural
    /// byte-run containing the letters "stream" (e.g. a /Downstream name)
    /// opened a phantom range reaching to the next `endstream` or EOF, and
    /// structural term matches inside that span were excluded from Layer 3's
    /// FAIL/WARN pass. The permissive scan (EOL optional — the pre-gate
    /// behavior) is retained ONLY as a fallback when the strict pass yields
    /// no ranges at all, so a malformed writer's streams are still excluded
    /// rather than raw-byte-scanned (malformed-file tolerance; compressed
    /// stream bytes as false-positive fodder is the worse failure there).
    private func findStreamRanges(_ data: Data) -> [Range<Int>] {
        let strict = scanStreamRanges(data, requireKeywordEOL: true)
        if !strict.isEmpty { return strict }
        return scanStreamRanges(data, requireKeywordEOL: false)
    }

    private func scanStreamRanges(_ data: Data, requireKeywordEOL: Bool) -> [Range<Int>] {
        // ASCII bytes for marker detection
        let streamMarker: [UInt8] = [0x73, 0x74, 0x72, 0x65, 0x61, 0x6D]       // "stream"
        let endstreamMarker: [UInt8] = [0x65, 0x6E, 0x64, 0x73, 0x74, 0x72, 0x65, 0x61, 0x6D] // "endstream"

        var ranges: [Range<Int>] = []
        data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
            let count = rawBuffer.count
            var i = 0

            while i < count - streamMarker.count {
                // Look for "stream" not preceded by "end" (avoid matching "endstream" as "stream")
                guard memcmp(base + i, streamMarker, streamMarker.count) == 0 else {
                    i += 1
                    continue
                }
                // Verify not "endstream"
                if i >= 3 && memcmp(base + i - 3, endstreamMarker, endstreamMarker.count) == 0 {
                    i += streamMarker.count
                    continue
                }

                // Skip past "stream" + EOL (CR+LF or just LF)
                var dataStart = i + streamMarker.count
                if requireKeywordEOL {
                    // Strict: the keyword must be followed by CR LF or LF
                    // (§7.3.8) or this is not a stream keyword at all — an
                    // embedded byte-run like "Downstream" opens no range.
                    if dataStart + 1 < count, base[dataStart] == 0x0D, base[dataStart + 1] == 0x0A {
                        dataStart += 2
                    } else if dataStart < count, base[dataStart] == 0x0A {
                        dataStart += 1
                    } else {
                        i += 1
                        continue
                    }
                } else {
                    if dataStart < count && base[dataStart] == 0x0D { dataStart += 1 } // CR
                    if dataStart < count && base[dataStart] == 0x0A { dataStart += 1 } // LF
                }

                // Find "endstream"
                var j = dataStart
                while j < count - endstreamMarker.count {
                    if memcmp(base + j, endstreamMarker, endstreamMarker.count) == 0 {
                        break
                    }
                    j += 1
                }
                if j < count - endstreamMarker.count {
                    ranges.append(dataStart..<j)
                    i = j + endstreamMarker.count
                } else {
                    // Malformed: no endstream found, treat rest as stream data
                    ranges.append(dataStart..<count)
                    break
                }
            }
        }
        return ranges
    }

    // MARK: - Layer 4: Structural Verification (ENGINE §6.4)

    /// Returns (status, affectedPages) where affectedPages is non-nil
    /// only for per-page /AA findings (enables tappable page chips in UI).
    private func runLayer4Structural(_ doc: PDFDocument) throws -> (VerificationStatus, [Int]?) {
        // PERF-8 / CANCEL-001: entry-level cooperative cancellation.
        try Task.checkCancellation()
        guard let (pdfData, cgDoc) = loadPDFData(doc),
              let catalog = cgDoc.catalog else {
            return (.warn("Could not inspect document structure"), nil)
        }

        // FAIL-triggering keys
        // ENGINE §6.4: Keys that indicate active content or encryption in the
        // document catalog. /AA triggers automatic actions (can execute JS on
        // open/close/print). /Encrypt should never appear in redacted output.
        // /RichMedia and /Flash can embed content containing PII.
        let failKeys = ["JavaScript", "JS", "OpenAction", "Launch",
                        "EmbeddedFiles", "SubmitForm", "ResetForm", "AcroForm",
                        "AA", "Encrypt", "RichMedia", "Flash"]
        for key in failKeys {
            var obj: CGPDFObjectRef?
            if CGPDFDictionaryGetObject(catalog, key, &obj) {
                return (.fail("\(key) found in document catalog"), nil)
            }
        }

        // ENGINE §6.4: the standard real-world carrier for embedded files and
        // document-level JavaScript is the catalog's /Names name-dictionary
        // (/Names → /EmbeddedFiles, /Names → /JavaScript), not the catalog top
        // level the loop above covers. Resecta's writer never emits /Names, so
        // these subtrees are active-content carriers wherever they appear; a
        // plain /Names without them stays on the generic WARN path below.
        var namesDict: CGPDFDictionaryRef?
        if CGPDFDictionaryGetDictionary(catalog, "Names", &namesDict), let namesDict {
            for key in ["EmbeddedFiles", "JavaScript"] {
                var subtree: CGPDFDictionaryRef?
                if CGPDFDictionaryGetDictionary(namesDict, key, &subtree) {
                    return (.fail("\(key) found under /Names in document catalog"), nil)
                }
            }
        }

        // ENGINE §6.4: Check per-page /AA entries. Page-level automatic actions
        // can trigger JavaScript or URI opens that leak document content.
        // Collects all affected pages for tappable navigation in the UI.
        let pageCount = cgDoc.numberOfPages
        var aaPages: [Int] = []
        for pageIdx in 1...max(1, pageCount) {
            try Task.checkCancellation()
            guard let pageDictRef = cgDoc.page(at: pageIdx)?.dictionary else { continue }
            var aaObj: CGPDFObjectRef?
            if CGPDFDictionaryGetObject(pageDictRef, "AA", &aaObj) {
                aaPages.append(pageIdx - 1)  // 0-indexed for UI (LayerResultRow shows pageRef + 1)
            }
        }
        if !aaPages.isEmpty {
            return (.fail("Per-page /AA (automatic action) found on \(pageCountPhrase(aaPages.count))"), aaPages)
        }

        // WARN-triggering keys
        let warnKeys = ["URI", "Metadata", "Names",
                        "OCProperties", "PieceInfo"]
        var warnings: [String] = []
        for key in warnKeys {
            var obj: CGPDFObjectRef?
            if CGPDFDictionaryGetObject(catalog, key, &obj) {
                warnings.append(key)
            }
        }

        // Check for multiple %%EOF markers (incremental updates).
        // pdfData already loaded by loadPDFData (memory-mapped per ENGINE §6.3).
        let eofMarker = "%%EOF".data(using: .ascii)!
        var eofCount = 0
        var searchRange = pdfData.startIndex..<pdfData.endIndex
        while let range = pdfData.range(of: eofMarker, options: [], in: searchRange) {
            eofCount += 1
            searchRange = range.upperBound..<pdfData.endIndex
        }
        if eofCount > 1 {
            // ENGINE §6.4: Incremental updates can append original content
            // after redaction. Resecta's reconstructor writes a single clean
            // PDF stream — multiple markers indicate tampering or corruption.
            return (.fail("Multiple %%EOF markers (\(eofCount)) — incremental update may contain original content"), nil)
        }

        if !warnings.isEmpty {
            return (.warn("Structural findings: \(warnings.joined(separator: ", "))"), nil)
        }
        return (.pass, nil)
    }

    // MARK: - Layer 5: Metadata Verification (ENGINE §6.5)

    private func runLayer5Metadata(_ doc: PDFDocument) throws -> VerificationStatus {
        // PERF-8 / CANCEL-001: entry-level cooperative cancellation.
        try Task.checkCancellation()
        guard let (pdfData, cgDoc) = loadPDFData(doc) else {
            return .warn("Could not inspect metadata")
        }

        // Scan for XMP metadata BEFORE the /Info guard. XMP lives in
        // the document's /Metadata stream, independent of /Info; the prior
        // early `return .pass` on a nil /Info dictionary skipped the XMP scan
        // entirely, so a document carrying XMP but no /Info passed silently.
        // pdfData already loaded by loadPDFData (memory-mapped per ENGINE §6.3).
        let hasXMP = pdfData.range(of: "<?xpacket".data(using: .ascii)!) != nil
            || pdfData.range(of: "<x:xmpmeta>".data(using: .ascii)!) != nil
            || pdfData.range(of: "<rdf:RDF".data(using: .ascii)!) != nil

        // Check /Info dictionary. When absent, the XMP scan above is still
        // authoritative — surface it rather than passing blind.
        guard let infoDict = cgDoc.info else {
            return hasXMP
                ? .warn("Auto-injected metadata present: XMP metadata")
                : .pass
        }

        // Standard metadata keys to check. FAIL on key presence regardless of
        // value type or decode success. The prior GetString/GetName pair
        // silently passed keys whose value was an integer, array, or boolean
        // (e.g. `/Title 42`), contradicting the documented intent. A single
        // CGPDFDictionaryGetObject presence check fires on ANY value type
        // (string, name, integer, array, boolean) — bytes that don't decode under
        // PDFDocEncoding / UTF-16BE-BOM / UTF-8-BOM no longer fall through as
        // "absent," and Name-object values are covered without a second call.
        // CGPDFContext (Apple's writer) never emits these keys, so any presence
        // is suspicious.
        // ARCH §12.2: Never include metadata values in status messages.
        let sensitiveKeys = ["Title", "Author", "Subject", "Keywords", "Creator"]
        for key in sensitiveKeys {
            var obj: CGPDFObjectRef?
            if CGPDFDictionaryGetObject(infoDict, key, &obj) {
                return .fail("Metadata key /\(key) present")
            }
        }

        // /Producer, /CreationDate, /ModDate are Apple auto-injected (ENGINE
        // §5.4) — informational only; they ride in `infoFindings` so a clean
        // doc with only these doesn't bump the masthead off green.
        var infoFindings: [String] = []
        var warnings: [String] = []
        let expectedKeys = ["Producer", "CreationDate", "ModDate"]
        for key in expectedKeys {
            var str: CGPDFStringRef?
            if CGPDFDictionaryGetString(infoDict, key, &str) {
                infoFindings.append("/\(key)")
            }
        }

        // Check for /Trapped (can reveal document workflow — ENGINE §6.5)
        var trappedStr: CGPDFStringRef?
        if CGPDFDictionaryGetString(infoDict, "Trapped", &trappedStr) {
            warnings.append("/Trapped")
        }
        // Also check as name object (PDF spec allows /Trapped as name)
        var trappedName: UnsafePointer<CChar>?
        if CGPDFDictionaryGetName(infoDict, "Trapped", &trappedName) {
            if !warnings.contains("/Trapped") {
                warnings.append("/Trapped")
            }
        }

        // Enumerate all /Info keys — FAIL on non-standard keys with content.
        // Custom metadata entries could contain PII transferred from the source
        // document (e.g., app-specific classification, document routing).
        let standardKeys: Set<String> = [
            "Title", "Author", "Subject", "Keywords", "Creator",
            "Producer", "CreationDate", "ModDate", "Trapped"
        ]
        var nonStandardKeys: [String] = []
        CGPDFDictionaryApplyBlock(infoDict, { key, _, _ in
            let keyName = String(cString: key)
            if !standardKeys.contains(keyName) {
                nonStandardKeys.append(keyName)
            }
            return true
        }, nil)
        if !nonStandardKeys.isEmpty {
            // ARCH §12.2: Do not include key values — just names
            return .fail("Non-standard /Info key(s): \(nonStandardKeys.joined(separator: ", "))")
        }

        // XMP metadata — scanned above the /Info guard; fold the
        // result into the warnings here for the /Info-present message path.
        if hasXMP {
            warnings.append("XMP metadata")
        }

        if !warnings.isEmpty {
            // Mixed case: real concern present. Drop infoFindings from the
            // message — auto-injected metadata is implicit when /Trapped or
            // XMP exists, so surfacing only the actionable subset keeps the
            // user focused on what matters. /Trapped is workflow-set, not
            // auto-injected, so the message only claims auto-injection when
            // XMP is the sole entry.
            let onlyXMP = warnings.allSatisfy { $0 == "XMP metadata" }
            let prefix = onlyXMP ? "Auto-injected metadata present" : "Metadata present"
            return .warn("\(prefix): \(warnings.joined(separator: ", "))")
        }
        if !infoFindings.isEmpty {
            return .info("Auto-injected metadata present: \(infoFindings.joined(separator: ", "))")
        }
        return .pass
    }

    // MARK: - PDF Data Loading Helper

    /// Load raw PDF bytes and a CGPDFDocument from a PDFDocument.
    /// Prefers URL-based loading; the default-options `Data(contentsOf:)`
    /// is `.mappedIfSafe`, matching ENGINE §6.3.
    /// Falls back to dataRepresentation() for non-file documents.
    private func loadPDFData(_ doc: PDFDocument) -> (Data, CGPDFDocument)? {
        if let url = doc.documentURL,
           let data = try? Data(contentsOf: url),
           let cgDoc = CGPDFDocument(url as CFURL) {
            return (data, cgDoc)
        }
        guard let data = doc.dataRepresentation(),
              let provider = CGDataProvider(data: data as CFData),
              let cgDoc = CGPDFDocument(provider) else {
            return nil
        }
        return (data, cgDoc)
    }

    // MARK: - Layer 6: Spatial Verification (ENGINE §6.6)

    /// Dispatch spatial verification across all Searchable Redaction pages.
    /// Collects all failing pages for tappable navigation chips.
    /// Skips pages that fell back to Secure Rasterization (AD-7-1).
    ///
    /// DRAW-1: when any region on the page carries `vertices`, the spatial
    /// exclusion check uses polygon-or-rect intersection (rect for
    /// vertex-less regions, even-odd polygon for vertex-bearing). The
    /// helper accepts `regionShapes` so the verifier can choose per-region.
    private func runLayer6SpatialVerification(
        _ doc: PDFDocument,
        regions: [Int: [RedactionRegion]],
        perPageModes: [PipelineMode],
        verifier: SandwichVerification
    ) async throws -> (VerificationStatus, [Int]?) {
        // PERF-8 / CANCEL-001: entry-level cooperative cancellation.
        try Task.checkCancellation()
        var failingPages: [Int] = []
        var firstFailMessage: String?
        // Positional edge grazes (per-page WARN from the exclusion pass):
        // fold below FAIL and above the unreadable-page WARN.
        var grazePages: [Int] = []
        var firstGrazeMessage: String?
        // VQ-23: eligible pages PDFKit cannot open surface as a WARN when the
        // layer would otherwise PASS — see runLayer1TextExtraction.
        var unreadablePages: [Int] = []

        for i in 0..<doc.pageCount {
            try Task.checkCancellation()
            // AD-7-1: Skip pages that fell back to Secure Rasterization
            guard i < perPageModes.count, perPageModes[i] == .searchableRedaction else {
                continue
            }
            guard let page = doc.page(at: i) else {
                unreadablePages.append(i)
                continue
            }
            let pageRegions = regions[i] ?? []
            // Do NOT skip region-less pages. The empty pageRegions
            // flows through the maps below as regionShapes == [] into
            // verifySpatialExclusion, which (count-only guard) still runs the
            // SVT-1 origin-delta lattice — closing the glyph-position-tamper gap
            // on region-less searchable pages. Cost is bounded by the existing
            // 256-iteration cancellation cadence (PERF-8) in the lattice walk.

            // Convert regions to output page coordinates (EXP-011: output pages
            // always have zero-origin bounds)
            let outputBounds = page.bounds(for: .cropBox)
            let rectsInPoints = pageRegions.map {
                normalizedToPDFPageCoordinates($0.normalizedRect, pageRect: outputBounds)
            }
            // DRAW-1: build polygon-aware shapes. Polygon vertices are
            // converted into PDF-point-space via the same conversion the
            // rect path uses. Rect-only regions carry `polygonVertices ==
            // nil`. PD-8: `bounds` carries the un-expanded rect (the
            // unconditional 0pt floor + the band gate) and `expandedBounds`
            // the filter's safety-margin halo, so Layer 6 enforces the
            // same two-tier contract the character filter excludes by.
            let regionShapes: [RegionShape] = zip(pageRegions, rectsInPoints)
                .map { region, rect in
                    let expanded = rect.insetBy(
                        dx: -safetyMarginPoints, dy: -safetyMarginPoints
                    )
                    guard let normalized = region.vertices,
                          normalized.count >= 3 else {
                        return RegionShape(
                            expandedBounds: expanded, polygonVertices: nil,
                            bounds: rect
                        )
                    }
                    let inPoints = normalized.map { v in
                        normalizedToPDFPageCoordinates(
                            CGRect(x: v.x, y: v.y, width: 0, height: 0),
                            pageRect: outputBounds
                        ).origin
                    }
                    return RegionShape(
                        expandedBounds: expanded, polygonVertices: inPoints,
                        bounds: rect
                    )
                }

            let result = try await verifier.verifySpatialExclusion(
                outputPage: page,
                regionShapes: regionShapes,
                pageIndex: i
            )
            if case .fail(let msg) = result {
                failingPages.append(i)
                if firstFailMessage == nil { firstFailMessage = msg }
            } else if case .warn(let msg) = result {
                grazePages.append(i)
                if firstGrazeMessage == nil { firstGrazeMessage = msg }
            }
        }
        if let msg = firstFailMessage {
            return (.fail(msg), failingPages)
        }
        // Graze WARN outranks the unreadable-page WARN (mirror of FAIL's
        // masking above; the combined case is rare and the graze message is
        // the more actionable of the two).
        if let msg = firstGrazeMessage {
            return (.warn(msg), grazePages)
        }
        if !unreadablePages.isEmpty {
            return (unreadablePagesWarn(unreadablePages), unreadablePages)
        }
        return (.pass, nil)
    }

    // MARK: - Layer 7: Character Count Cross-Check (ENGINE §6.6)

    /// Dispatch character count verification across all Searchable Redaction pages.
    /// Collects all failing pages for tappable navigation chips.
    private func runLayer7CharacterCount(
        _ doc: PDFDocument,
        filterDigests: [PageFilterDigest?],
        perPageModes: [PipelineMode],
        verifier: SandwichVerification
    ) async throws -> (VerificationStatus, [Int]?) {
        // PERF-8 / CANCEL-001: entry-level cooperative cancellation.
        try Task.checkCancellation()
        var failingPages: [Int] = []
        var firstFailMessage: String?
        // Track how many pages this
        // digest-consuming layer was eligible to cross-check vs how many it
        // actually checked, so a layer that ran no comparisons reports the
        // truth (.skipped) instead of a silent .pass.
        var eligible = 0
        var checked = 0

        for i in 0..<doc.pageCount {
            try Task.checkCancellation()
            guard i < perPageModes.count, perPageModes[i] == .searchableRedaction else {
                continue
            }
            eligible += 1
            guard i < filterDigests.count, let digest = filterDigests[i] else {
                continue
            }
            guard let page = doc.page(at: i) else { continue }

            checked += 1
            let result = try await verifier.verifyCharacterCount(
                outputPage: page, digest: digest
            )
            if case .fail(let msg) = result {
                failingPages.append(i)
                if firstFailMessage == nil { firstFailMessage = msg }
            }
        }
        if let msg = firstFailMessage {
            return (.fail(msg), failingPages)
        }
        // Eligible-but-unchecked → honest .skipped (the verify-only
        // resume path rebuilds all-nil digests). Partial coverage → .warn
        // (defensive; unreachable today since digests are all-present or
        // all-nil). eligible == 0 stays .pass — skipped by design (every page
        // is per-page Secure Rasterization); promoting it would WARN-flag
        // valid docs (the false-positive trap one layer up).
        if eligible > 0 && checked == 0 {
            return (.skipped, nil)
        }
        if checked < eligible {
            return (.warn("Cross-checked \(checked) of \(eligible) \(eligible == 1 ? "page" : "pages") — remaining pages lacked rasterization data"), nil)
        }
        return (.pass, nil)
    }

    // MARK: - Layer 8: Font Verification (ENGINE §6.6)

    /// Dispatch font verification across all Searchable Redaction pages.
    /// Collects all failing pages for tappable navigation chips.
    private func runLayer8FontVerification(
        _ doc: PDFDocument,
        perPageModes: [PipelineMode],
        verifier: SandwichVerification
    ) async throws -> (VerificationStatus, [Int]?) {
        // PERF-8 / CANCEL-001: entry-level cooperative cancellation.
        try Task.checkCancellation()
        var failingPages: [Int] = []
        var firstFailMessage: String?
        // VQ-23: see runLayer1TextExtraction — unreadable eligible pages WARN
        // on the otherwise-PASS path.
        var unreadablePages: [Int] = []

        for i in 0..<doc.pageCount {
            try Task.checkCancellation()
            guard i < perPageModes.count, perPageModes[i] == .searchableRedaction else {
                continue
            }
            guard let page = doc.page(at: i) else {
                unreadablePages.append(i)
                continue
            }

            let result = try await verifier.verifyFontsAreMonospace(
                outputPage: page, pageIndex: i)
            if case .fail(let msg) = result {
                failingPages.append(i)
                if firstFailMessage == nil { firstFailMessage = msg }
            }
        }
        if let msg = firstFailMessage {
            return (.fail(msg), failingPages)
        }
        if !unreadablePages.isEmpty {
            return (unreadablePagesWarn(unreadablePages), unreadablePages)
        }
        return (.pass, nil)
    }

    // MARK: - Layer 9: Character Lineage (ENGINE §6.6 SVT-2)

    /// Dispatch character-lineage verification across all Searchable Redaction
    /// pages. Re-computes the SHA-256 over output composed-character iteration
    /// and reports mismatch against `PageFilterDigest.lineageHash`. Reorderings,
    /// insertions, deletions, and replacements of non-zero-bounds composed
    /// characters between filter and final PDF flip the hash. Zero-width
    /// insertions do NOT — both sides iterate non-zero-bounds composed
    /// characters only (pinned M4 residual; term-bearing injections are
    /// covered by Layers 3/10, SVT-3/SVT-5). See plan §4.4 and
    /// `SandwichVerification.verifyCharacterLineage`.
    private func runLayer9CharacterLineage(
        _ doc: PDFDocument,
        filterDigests: [PageFilterDigest?],
        perPageModes: [PipelineMode],
        verifier: SandwichVerification
    ) async throws -> (VerificationStatus, [Int]?) {
        // PERF-8 / CANCEL-001 (VQ-24): entry-level cooperative cancellation +
        // a per-page check, matching every other layer dispatcher; the
        // composed-character walk inside the verifier carries the banded
        // 256-cadence checks. `runLayer` converts the CancellationError to
        // `.skipped` exactly as for Layers 1–8.
        try Task.checkCancellation()
        var failingPages: [Int] = []
        var firstFailMessage: String?
        // See runLayer7CharacterCount — same
        // eligible/checked accounting so an unchecked digest-consuming layer
        // reports .skipped rather than a silent .pass.
        var eligible = 0
        var checked = 0

        for i in 0..<doc.pageCount {
            try Task.checkCancellation()
            guard i < perPageModes.count, perPageModes[i] == .searchableRedaction else {
                continue
            }
            eligible += 1
            guard i < filterDigests.count, let digest = filterDigests[i] else {
                continue
            }
            guard let page = doc.page(at: i) else { continue }

            checked += 1
            let result = try await verifier.verifyCharacterLineage(
                outputPage: page, digest: digest
            )
            if case .fail(let msg) = result {
                failingPages.append(i)
                if firstFailMessage == nil { firstFailMessage = msg }
            }
        }
        if let msg = firstFailMessage {
            return (.fail(msg), failingPages)
        }
        // Eligible-but-unchecked → .skipped; partial → .warn;
        // eligible == 0 stays .pass (skipped by design). See Layer 7.
        if eligible > 0 && checked == 0 {
            return (.skipped, nil)
        }
        if checked < eligible {
            return (.warn("Cross-checked \(checked) of \(eligible) \(eligible == 1 ? "page" : "pages") — remaining pages lacked rasterization data"), nil)
        }
        return (.pass, nil)
    }
}

// Grammatical page phrases, wording only. The prior
// "on 1 page(s): 1" form both dodged the plural and repeated the count
// as the list. Verdict levels and thresholds at every call site are
// untouched.
private func pagePhrase(_ pages: [Int], list: String) -> String {
    pages.count == 1 ? "page \(list)" : "\(pages.count) pages: \(list)"
}

private func pageCountPhrase(_ count: Int) -> String {
    count == 1 ? "1 page" : "\(count) pages"
}

/// VQ-23: WARN copy for pages a per-page layer loop could not open
/// (Layers 1/6/8), mirroring Layer 10's per-page unavailability shape.
/// `pages` are 0-based (the UI chip convention); the copy prints 1-based
/// numbers — a single page by number, multiple as count + list.
private func unreadablePagesWarn(_ pages: [Int]) -> VerificationStatus {
    let list = pages.map { String($0 + 1) }.joined(separator: ", ")
    return pages.count == 1
        ? .warn("Page \(list) could not be read for this check")
        : .warn("\(pages.count) pages could not be read for this check: \(list)")
}

/// Partial-drop honesty tail for the term-search layers (3 and 10): reported
/// on the otherwise-clean path when some but not all sensitive terms were too
/// short to search (`AhoCorasick.isSearchableTerm`). Internal — shared with
/// `SandwichVerification.verifyTextOperatorSemantics`.
func shortTermTail(_ droppedCount: Int) -> String {
    droppedCount == 1
        ? "1 term too short to check"
        : "\(droppedCount) terms too short to check"
}
