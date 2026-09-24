import Foundation
import PDFKit
import Vision
import ImageIO
#if canImport(UIKit)
import UIKit  // PDFPage.thumbnail(of:for:) returns UIImage
#else
import AppKit  // macOS tooling destination: thumbnail returns NSImage
#endif

// Verification engine. Each check is a `VerificationLayer` case; the
// per-mode order and count come from `layers(for:)` (Secure Rasterization
// runs six checks, Searchable Redaction eleven; the search re-check is last
// in both), never from an index table.

/// Stateless verification engine. Runs individual layers on output PDFs.
public struct VerificationEngine: Sendable {

    /// Confidence threshold for Layer 2 OCR check.
    /// 0.50 is standard for text recognition — reduces noise from bitmap
    /// artifacts while still detecting leaked text.
    static let ocrConfidenceThreshold: Float = 0.50

    /// FAIL confidence gate for a sensitive-term-in-region hit.
    /// Equal to `ocrConfidenceThreshold` so the FAIL is double-gated (region
    /// overlap AND term match); exposed as its own constant so an
    /// adjustment to a stricter value (e.g. 0.75) is a one-line change.
    static let sensitiveTermFailConfidenceThreshold: Float = ocrConfidenceThreshold

    /// Minimum fraction of an OCR word/line box that must lie inside a redacted
    /// region for the hit to count as "in region". Replaces the
    /// prior any-overlap test (`CGRect.intersects`), under which the bounding box
    /// of an adjacent still-visible word clipping a mid-line region's edge by a
    /// sliver counted as in-region. In Secure Rasterization the region is painted
    /// opaque (`PageRasterizer.applyRedactionFills`, blend `.copy`) and post-fill
    /// `verifyFill` proves the pixels are the fill colour, so no readable glyph
    /// can sit inside a correctly-filled region — the only box that can touch a
    /// region edge is neighbouring text. A real paint miss leaves glyphs
    /// substantially inside the region (fraction → 1.0, still a FAIL); an
    /// edge-clipping sliver is a small fraction (≪ 0.5) and is dropped. Threshold
    /// is inclusive (`>=`).
    static let inRegionCoverageThreshold: CGFloat = 0.5

    /// Bounded width for the Layer-2 OCR task group. Vision's own
    /// internal concurrency bounds the realized speed-up; a private constant so
    /// tuning needs no source-logic change. It is a `nonisolated(unsafe) static
    /// var` purely so the wall-clock acceptance gate can measure width-1 (serial)
    /// against width-3 on the one production code path — production never mutates
    /// it (the perf test is `.serialized` + `.disabled`, run on demand alone).
    /// The width bounds pages-resident memory and the overlap of
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
    static let ocrMaxPixelDimension = 4096

    public init() {}

    /// Test seam: observes the `PDFDocument` identity each
    /// `runLayer` call receives, so a guard test can assert the parallel base
    /// batch gives each layer its own instance (no shared-PDFKit-object
    /// concurrency). Nil in production — the `?.` invocation below compiles to a
    /// no-op. `VerificationEngine` is a value type, so set this on the verifier
    /// value BEFORE passing it into `collectParallelBaseLayerResults`; the
    /// per-task copies the fan-out makes each carry the closure.
    public var onRunLayerDispatch: (@Sendable (Int, ObjectIdentifier) -> Void)?

    /// Canonical per-mode layer order: every `VerificationLayer` that applies
    /// to `mode`, in declaration order (`searchRecheck` last in both modes).
    /// Counts, ordinals and the coordinator's schedule derive from this list.
    public func layers(for mode: PipelineMode) -> [VerificationLayer] {
        VerificationLayer.allCases.filter { $0.appliesTo(mode) }
    }

    /// Total layer count for a given pipeline mode (never hardcoded).
    public func layerCount(for mode: PipelineMode) -> Int {
        layers(for: mode).count
    }

    /// Human-readable name for the layer at `index` in `mode`'s order.
    public func layerName(at index: Int, mode: PipelineMode) -> String {
        let ordered = layers(for: mode)
        return ordered.indices.contains(index) ? ordered[index].name : "Unknown Layer"
    }

    /// Index-only adapter over the Searchable order (`VerificationLayer
    /// .allCases`): indices 0–9 are identical in both modes; index 10 is the
    /// Search Re-check. Kept for index-keyed callers; new code reads
    /// `layerName(at:mode:)` or the layer's own `name`. The symbol lives on
    /// the layer (`VerificationLayer.symbolName`) and on each result
    /// (`LayerResult.symbolName`); no index-keyed symbol adapter remains.
    public func layerName(at index: Int) -> String {
        let all = VerificationLayer.allCases
        return all.indices.contains(index) ? all[index].name : "Unknown Layer"
    }

    /// Run a single verification layer by its index in `pipelineMode`'s
    /// order (`layers(for:)`). Adapter over `runLayer(_ layer:…)` for the
    /// index-keyed callers; the range check is the same fail-fast
    /// precondition (a silent `.pass` on an out-of-range index would let
    /// caller bugs masquerade as verification success).
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
        let ordered = layers(for: pipelineMode)
        precondition(
            layerIndex >= 0 && layerIndex < ordered.count,
            "runLayer called with out-of-range layerIndex \(layerIndex) for mode \(pipelineMode)"
        )
        return await runLayer(
            ordered[layerIndex],
            outputDocument: outputDocument,
            sourcePageCount: sourcePageCount,
            regions: regions,
            sensitiveTerms: sensitiveTerms,
            pipelineMode: pipelineMode,
            filterDigests: filterDigests,
            perPageModes: perPageModes
        )
    }

    /// Run a single verification layer. `appliedSearches` feeds the Search
    /// Re-check only (every other layer ignores it); empty ⇒ that layer
    /// reports INFO.
    @concurrent
    public func runLayer(
        _ layer: VerificationLayer,
        outputDocument: SendablePDFDocument,
        sourcePageCount: Int,
        regions: [Int: [RedactionRegion]],
        sensitiveTerms: [SensitiveTerm],
        pipelineMode: PipelineMode,
        filterDigests: [PageFilterDigest?],
        perPageModes: [PipelineMode],
        appliedSearches: [SearchRecheckRequest] = []
    ) async -> LayerResult {
        // A layer that does not apply to the mode is a caller bug; a silent
        // .pass would masquerade as verification success. Fail fast instead.
        let ordered = layers(for: pipelineMode)
        precondition(
            ordered.contains(layer),
            "runLayer called with layer \(layer) that does not apply to mode \(pipelineMode)"
        )
        let ordinal = ordered.firstIndex(of: layer) ?? 0

        let start = CFAbsoluteTimeGetCurrent()
        let doc = outputDocument.document

        // Guard seam: record which document instance this layer was
        // dispatched against. No-op in production (closure is nil).
        onRunLayerDispatch?(ordinal, ObjectIdentifier(doc))

        let sandwichVerifier = SandwichVerification()

        var status: VerificationStatus
        var layerPageReferences: [Int]? = nil
        // Display-only term texts behind an `.attention` result (Layers 2, 3
        // and 10, and the Search Re-check) — threaded into
        // LayerResult.reviewTermTexts; nil elsewhere.
        var layerReviewTerms: [String]? = nil
        // A layer that supplies its own PASS/ATTENTION/WARN copy (the
        // Search Re-check; the Layer-7 promotion below is the precedent).
        var copyOverride: SearchRecheck.Copy? = nil
        // Display-only per-query lines (Search Re-check only).
        var layerQueryLines: [SearchRecheckQueryLine]? = nil
        // The layer's own classification of a WARN that says the check did
        // not fully run (see `LayerResult.couldNotVerify`); each dispatcher
        // returns it beside its status, `false` for every WARN that reports
        // what a check saw.
        var couldNotVerify = false

        // Each layer method calls
        // `try Task.checkCancellation()` on entry (and within long inner
        // loops for layers that walk many pages or characters). A
        // CancellationError thrown from a layer is converted below into a
        // `.skipped` LayerResult so the coordinator's between-layer
        // `try Task.checkCancellation()` then surrenders the pipeline.
        // Keeps `runLayer`'s public signature non-throwing.
        do { // LegalPhrases:safe (Swift keyword usage below)
            switch layer {
            case .textExtraction:
                let (s0, pages0, cnv0) = try runLayer1TextExtraction(
                    doc, pipelineMode: pipelineMode, perPageModes: perPageModes)
                status = s0
                layerPageReferences = pages0
                couldNotVerify = cnv0
            case .ocrCheck:
                // Layer 2's OCR gate applies the same per-term boundary
                // discipline as the byte layers (String-space mirror in
                // `containsTerm`), so a boundary-required name term cannot
                // substring-match inside an unrelated word read off a raster.
                // The third element carries the display-only term texts
                // behind an `.attention` verdict (Layer 3's shape).
                let (s1, pages1, terms1, cnv1) = try await runLayer2OCR(
                    doc, pipelineMode: pipelineMode,
                    regions: regions, sensitiveTerms: sensitiveTerms,
                    perPageModes: perPageModes)
                status = s1
                layerPageReferences = pages1
                layerReviewTerms = terms1
                couldNotVerify = cnv1
            case .binaryStringSearch:
                let (s2, pages2, terms2, cnv2) = try runLayer3BinarySearch(doc, sensitiveTerms: sensitiveTerms)
                status = s2
                layerPageReferences = pages2
                layerReviewTerms = terms2
                couldNotVerify = cnv2
            case .structureCheck:
                let (s, pages, cnv3) = try runLayer4Structural(doc)
                status = s
                layerPageReferences = pages
                couldNotVerify = cnv3
            case .metadataCheck:
                let (s4, cnv4) = try runLayer5Metadata(doc)
                status = s4
                couldNotVerify = cnv4
            // Layers 6–10: Sandwich-specific.
            // Only run for Searchable Redaction pages.
            case .spatialVerification:
                let (s5, pages5, cnv5) = try await runLayer6SpatialVerification(
                    doc, regions: regions, perPageModes: perPageModes,
                    verifier: sandwichVerifier)
                status = s5
                layerPageReferences = pages5
                couldNotVerify = cnv5
            case .characterCount:
                let (s6, pages6, cnv6) = try await runLayer7CharacterCount(
                    doc, filterDigests: filterDigests, perPageModes: perPageModes,
                    verifier: sandwichVerifier)
                status = s6
                layerPageReferences = pages6
                couldNotVerify = cnv6
            case .fontVerification:
                let (s7, pages7, cnv7) = try await runLayer8FontVerification(
                    doc, perPageModes: perPageModes, verifier: sandwichVerifier)
                status = s7
                layerPageReferences = pages7
                couldNotVerify = cnv7
            case .characterLineage:
                let (s8, pages8, cnv8) = try await runLayer9CharacterLineage(
                    doc, filterDigests: filterDigests, perPageModes: perPageModes,
                    verifier: sandwichVerifier)
                status = s8
                layerPageReferences = pages8
                couldNotVerify = cnv8
            case .operatorReExtraction:
                // Layer 10 — operator-semantic re-extraction.
                // Independent of `regions`, `perPageModes`, `filterDigests`, and
                // `sourcePageCount`: walks the output content streams directly.
                // Pairs with Layer 3 as a two-decoder cross-check.
                let l10 = await sandwichVerifier.verifyTextOperatorSemantics(
                    outputDocument: outputDocument,
                    sensitiveTerms: sensitiveTerms
                )
                status = l10.status
                layerPageReferences = l10.pageReferences
                layerReviewTerms = l10.reviewTermTexts
                couldNotVerify = l10.couldNotVerify
            case .searchRecheck:
                // Search Re-check — re-runs every applied search on the
                // output through the search engine itself (text layer or the
                // searcher's own OCR path per page). Supplies its own
                // PASS/ATTENTION/WARN copy; INFO when nothing was applied.
                let outcome = try await SearchRecheck().run(
                    outputDocument: outputDocument,
                    requests: appliedSearches,
                    perPageModes: perPageModes
                )
                status = outcome.status
                layerPageReferences = outcome.pageReferences
                layerReviewTerms = outcome.reviewTermTexts
                copyOverride = outcome.copyOverride
                layerQueryLines = outcome.queryLines
                // The re-check's only WARN family is its unchecked-pages
                // one (pages it could not open or read, OCR it could not
                // run, pages over its caps): a WARN here always says the
                // re-check did not fully run.
                couldNotVerify = outcome.status.isWarn
            }
        } catch is CancellationError { // LegalPhrases:safe (Swift keyword)
            let duration = CFAbsoluteTimeGetCurrent() - start
            let name = layer.name
            let symbol = layer.symbolName
            return LayerResult(
                name: name, symbolName: symbol, status: .skipped,
                shortDescription: "Skipped.",
                detailDescription: "\(name) was not run because the operation was cancelled.",
                pageReferences: nil, durationSeconds: duration,
                layer: layer
            )
        } catch { // LegalPhrases:safe (Swift keyword)
            // Unexpected non-cancellation error — surface as fail so caller sees
            // something went wrong rather than silently passing.
            let duration = CFAbsoluteTimeGetCurrent() - start
            let name = layer.name
            let symbol = layer.symbolName
            return LayerResult(
                name: name, symbolName: symbol,
                status: .fail("Layer threw unexpected error"),
                shortDescription: "Layer threw unexpected error.",
                detailDescription: "\(name) threw an unexpected error while checking the document.",
                pageReferences: nil, durationSeconds: duration,
                layer: layer
            )
        }

        let duration = CFAbsoluteTimeGetCurrent() - start
        let name = layer.name
        let symbol = layer.symbolName

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
        if layer == .characterCount, status == .pass {
            let totalBoundary = filterDigests.compactMap { $0 }
                .reduce(0) { $0 + $1.boundaryCharacters.count }
            if totalBoundary > 0 {
                shortDesc = "\(totalBoundary) character\(totalBoundary == 1 ? "" : "s") near redaction boundaries."
                detailDesc = "\(name) completed with no findings. \(totalBoundary) character\(totalBoundary == 1 ? "" : "s") detected near redaction boundaries."
                status = .info(shortDesc)
            }
        }

        // A layer-supplied copy replaces the generic composition for the
        // status it was composed for (PASS / ATTENTION / WARN); INFO, FAIL and
        // skipped always use the generic lines.
        if let copyOverride, status == .pass || status.isAttention || status.isWarn {
            shortDesc = copyOverride.short
            detailDesc = copyOverride.detail
        }

        return LayerResult(
            name: name, symbolName: symbol, status: status,
            shortDescription: shortDesc, detailDescription: detailDesc,
            pageReferences: layerPageReferences, durationSeconds: duration,
            reviewTermTexts: layerReviewTerms,
            layer: layer,
            queryLines: layerQueryLines,
            couldNotVerify: couldNotVerify
        )
    }

    /// Aggregate per-layer results into overall status.
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

    // MARK: - Layer 1: Text Extraction

    /// Returns (status, affectedPages). Page-level findings (selectable text,
    /// annotations) are accumulated across ALL pages — not returned at the
    /// first offending page — so a multi-page problem surfaces in one run,
    /// and the 0-based page list feeds the tappable page chips in the UI.
    /// Document-level findings (bookmarks, AcroForm) carry nil references.
    /// The selectable-text test keys on each page's OWN mode
    /// (`perPageModes`, falling back to the document mode for pages beyond
    /// the array): a page that fell back to Secure Rasterization inside a
    /// Searchable run was written image-only and must carry no text layer —
    /// the same per-page reading Layer 2 makes.
    private func runLayer1TextExtraction(
        _ doc: PDFDocument,
        pipelineMode: PipelineMode,
        perPageModes: [PipelineMode]
    ) throws -> (VerificationStatus, [Int]?, Bool) {
        // Entry-level cooperative cancellation.
        try Task.checkCancellation()
        var selectableTextPages: [Int] = []
        var annotationPages: [Int] = []
        // Pages PDFKit cannot open were previously skipped silently and
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

            // Check for selectable text against the page's own mode.
            if let text = page.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let pageMode = i < perPageModes.count ? perPageModes[i] : pipelineMode
                if pageMode == .secureRasterization {
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
                    selectableTextPages, false)
        }
        if !annotationPages.isEmpty {
            let list = annotationPages.map { String($0 + 1) }.joined(separator: ", ")
            return (.fail("Annotations found on \(pagePhrase(annotationPages, list: list))"),
                    annotationPages, false)
        }

        // Check document-level structures
        if doc.outlineRoot != nil {
            return (.fail("Bookmarks found in output"), nil, false)
        }

        // Check for /AcroForm via CGPDFDocument. A silent no-op on any nil
        // in this chain would mask AcroForm presence — Layer 4 handles the
        // identical failure mode by returning .warn, so match that here.
        guard let url = doc.documentURL,
              let cgDoc = CGPDFDocument(url as CFURL),
              let catalog = cgDoc.catalog else {
            return (.warn("Could not verify /AcroForm absence"), nil, true)
        }
        var acroForm: CGPDFDictionaryRef?
        if CGPDFDictionaryGetDictionary(catalog, "AcroForm", &acroForm) {
            return (.fail("Form fields found in output"), nil, false)
        }

        // No leak reported, but some pages were never inspected —
        // an honest WARN, not a clean PASS.
        if !unreadablePages.isEmpty {
            return (unreadablePagesWarn(unreadablePages), unreadablePages, true)
        }
        return (.pass, nil, false)
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
    // strict values and finalized unchanged by an adversarial battery
    // (`Layer2FillGuardBatteryTests`, iOS 26.4): the real drivers measure
    // byte-exact fill (1.000 / 0.000 / maxDev ≤ 0.012) while every readable-leak
    // class the battery could surface through Vision holds a wide margin on at
    // least one floor (per-constant margins below). Demotion tier (updated
    // 2026-07-09): the demotion folds to an informational note — visible in
    // Verification Details, never affecting pass/fail — on BOTH page modes; any
    // further promotion of provable tier-1 boxes (e.g. suppressing the note
    // entirely) would be a policy change, not a tuning.

    /// Δ_fill — full-RGB (per-channel Chebyshev) distance within which a pixel is
    /// "essentially the fill colour"; generous enough to absorb JPEG q0.92 noise
    /// on a solid bar. 0…1. Measured: a uniform dev-0.149 field still counts
    /// as fill, dev-0.1725 does not (battery `propertyFloors_pure`).
    private static let fillDistance: CGFloat = 0.16
    /// Δ_contrast — distance at/over which a pixel counts as readable contrast.
    /// MUST be ≤ `fillDistance` (asserted in `isFillConsistent`) so the bands are
    /// complementary — no dead zone a pale-but-readable stroke can hide in. Set
    /// below the readability JND and above JPEG noise. 0…1. Measured: the
    /// palest Vision-readable ink the battery measured deviates ≥ 0.176
    /// (gray-45 on black; pale-on-white F-WEBER ink deviates ≈ 0.18 with its
    /// loose-band break only at a hypothetical Δ_contrast ≥ 44/255 ≈ 0.173 —
    /// unreachable while Δ_contrast ≤ Δ_fill = 0.16 holds). Band pin: dev
    /// 0.1098 is fill-only; dev 0.1294 already counts as contrast.
    private static let contrastDistance: CGFloat = 0.12
    /// F_min — minimum in-region-portion fill fraction for a box to be a demotion
    /// candidate (efficacy floor). Because `contrastFraction >= 1 - fillFraction`
    /// (every non-fill pixel is a contrast pixel, given Δ_contrast ≤ Δ_fill),
    /// demotion already implies `fillFraction >= 1 - contrastCeil`. Measured:
    /// real drivers fill = 1.000 (margin 0.03 above); the fullest readable-leak
    /// box measured 0.938 (gray-45) — 0.032 below the floor. The battery's
    /// chroma×hairline probe (blue-115 ultralight, below Vision's `.fast`
    /// sensor floor) starves BOTH the recall floor (contrast 0.076) and the
    /// outlier floor (maxDev 0.470) at once — this fill floor is what refuses
    /// it, at 0.934 (margin 0.036): the tightest measured approach to the
    /// demotion region by any ink class.
    private static let fillFloor: CGFloat = 0.97
    /// C_max — maximum readable-contrast fraction for a demotion candidate
    /// (≤ 0.03 by charter). The binding safety constraint. Measured: drivers
    /// contrast = 0.000; the faintest readable-leak contrast measured 0.096
    /// (hairline ultralight digits) — 3.2× the ceiling, and that box is also
    /// refused by the fill floor (0.906) and the outlier floor (maxDev 0.986).
    private static let contrastCeil: CGFloat = 0.03
    /// Recall-floor invariant: a box with at least this much readable contrast is
    /// NEVER excluded, regardless of `fillFraction`. Structural — it holds even if
    /// `contrastCeil` were later loosened past it. Cannot be tuned away. The
    /// battery's readable-leak contrast spans 0.096–0.995; the 0.096 hairline
    /// row rides the composed fill/outlier floors (see `contrastCeil`), every
    /// other class clears this floor outright.
    private static let recallFloor: CGFloat = 0.10
    /// Outlier floor: a single pixel this far (full-RGB) from the fill is
    /// "definitely ink" (the dark/contrasting core of a real glyph, including
    /// coloured ink whose luminance ≈ the fill) and blocks exclusion. 0…1.
    /// Measured: drivers maxDev ≤ 0.012 (0.488 below); hairline/reverse-video
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
    /// fixture driver demotes and the recall ink is still KEPT. Tiny-strip
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
    /// based so the pixel math is directly unit-testable without Vision.
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
    /// buffer is zeroized on exit so output pixels do not linger in heap.
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
                // Fill-consistency is classified against the
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
                // never a clean PASS — the precision-only bar holds (the verifier may route the
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

    /// Per-word normalized boxes for a recognized line, mirroring
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
        // construction), even when the DOCUMENT ran in Searchable mode
        // and only this page fell back to rasterization. The fold FAILs the
        // secure-raster list and keeps the Searchable list on the existing WARN.
        case textInRegionSecureRaster
        case textInRegionSearchable
        // A sensitive term readable OUTSIDE every region (the classifier's
        // `.sensitiveTermOutsideRegions`) on either page mode: the fold
        // reports ATTENTION with the term texts — see `foldLayer2PageOutcomes`.
        case sensitiveTermOutsideRegions
        case fillArtifactInRegion
        case textOutsideRegionsOnly
        case unmappable
        case unchecked
        case clean
    }

    /// One page's folded Layer-2 outcome. A named tuple type so the task group's
    /// `of:` argument and the accumulator stay unambiguous.
    typealias PageOutcome = (page: Int, bucket: PageOCRBucket)

    /// One page's Layer-2 result as it leaves the OCR task group: the folded
    /// outcome plus, for a `.sensitiveTermOutsideRegions` page, the matched
    /// term texts the results row names (empty for every other bucket).
    struct PageOCRResult: Sendable {
        let outcome: PageOutcome
        let reviewTermTexts: [String]

        init(_ page: Int, _ bucket: PageOCRBucket, reviewTermTexts: [String] = []) {
            self.outcome = (page, bucket)
            self.reviewTermTexts = reviewTermTexts
        }
    }

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

    /// The verifier's one Vision seam. `VNImageRequestHandler
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
    /// request. (The same pattern applies in `DetectionOrchestrator.runOCR` — acceptable
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

    /// Maps one page's classifier finding to its fold bucket. Static seam so
    /// the mapping matrix is unit-testable without Vision
    /// (`Layer2FoldOrderTests`); `classifyPageImages` is its only caller.
    static func pageBucket(
        for finding: PageOCRFinding, effectiveMode: PipelineMode
    ) -> PageOCRBucket {
        switch finding {
        case .sensitiveTermInRegion:
            return .sensitiveTermInRegion   // fail outranks every other case
        case .textInRegion:
            // Bucketed by the PAGE's mode: a rasterized page's region holds
            // no readable text by construction, so an in-region hit there is
            // a leak (folds to FAIL) even when the document mode is
            // Searchable and only this page fell back.
            return effectiveMode == .secureRasterization
                ? .textInRegionSecureRaster : .textInRegionSearchable
        case .fillArtifactInRegion:
            // Vision hallucinated tokens out of the solid fill itself — no
            // readable ink (full-RGB fill-consistent on the in-region portion).
            // The classification applies on BOTH page modes: a painted fill
            // bar is the same pixels either way, so a proven fill artifact
            // folds to the informational note regardless of the page's mode.
            // A non-proven in-region hit on a Searchable page keeps the
            // textInRegion WARN path above.
            return .fillArtifactInRegion
        case .sensitiveTermOutsideRegions:
            // A term the user redacted is still readable outside every
            // region — the redaction itself is intact, but an un-redacted
            // occurrence survives (one the user did not select or detection
            // missed). Its own bucket on BOTH page modes: the fold reports
            // ATTENTION with the term texts, the tier Layer 3 and the Search
            // Re-check give the same condition (a rasterized page has no
            // text layer for them to read, so Layer 2 is the only layer that
            // can see it there). In-region survivors still FAIL above.
            return .sensitiveTermOutsideRegions
        case .textOutsideRegionsOnly:
            return .textOutsideRegionsOnly
        case .none:
            return .clean
        }
    }

    /// OCR every (already-downsampled) image on one page and fold the
    /// result into a single Layer-2 bucket. No PDFKit — so the bounded task group
    /// runs pages concurrently. Mirrors the per-page body of the original
    /// sequential loop exactly; only the dispatch shape changed. The Vision
    /// perform itself hops to the serial `visionPerformQueue` (see
    /// `layer2OCRHits`) so no cooperative-pool thread blocks inside Vision.
    private static func classifyPageImages(
        _ work: PageOCRWork,
        sensitiveTerms: [SensitiveTerm]
    ) async throws -> PageOCRResult {
        // Run OCR on EVERY image with the FROZEN verificationLayer2 preset
        // (.fast, no language correction) at the moderate confidence threshold
        // — 0.50 reduces bitmap-artifact noise while detecting
        // leaked text; Layers 1 and 3 give independent coverage. Later OCR
        // tuning work must not retune the verifier. An OCR error on ANY of the
        // page's images means the page was not fully checked — fold it into the
        // `.unchecked` WARN rather than letting the missing image read as clean.
        var hits: [OCRHit] = []
        for pageImage in work.images {
            try Task.checkCancellation()
            guard let imageHits = await Self.layer2OCRHits(in: pageImage) else {
                return PageOCRResult(work.page, .unchecked)
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
            let classification = Self.classifyPageOCR(
                hits: enriched, pageRegions: work.pageRegions, sensitiveTerms: sensitiveTerms)
            // Only a term-outside page carries term texts, read from the
            // SAME hits, regions and terms the classifier saw, so the names
            // the results row shows are exactly the matches behind the
            // verdict.
            let reviewTermTexts = classification == .sensitiveTermOutsideRegions
                ? Self.outsideRegionTermTexts(
                    hits: enriched, pageRegions: work.pageRegions, sensitiveTerms: sensitiveTerms)
                : []
            return PageOCRResult(
                work.page, Self.pageBucket(for: classification, effectiveMode: work.effectiveMode),
                reviewTermTexts: reviewTermTexts)
        } else if !work.pageRegions.isEmpty,
                  hits.contains(where: { !($0.text ?? "").isEmpty }) {
            // Unmappable coordinates with a redaction region present: text might
            // sit inside a region but cannot be confirmed. Conservative WARN
            // (C-B contract: never identity-map unmappable observations).
            return PageOCRResult(work.page, .unmappable)
        } else if work.effectiveMode == .searchableRedaction,
                  hits.contains(where: { !($0.text ?? "").isEmpty }) {
            // No regions to violate — selectable text on a Searchable page is
            // expected; keep the INFO continuity.
            return PageOCRResult(work.page, .textOutsideRegionsOnly)
        }
        return PageOCRResult(work.page, .clean)
    }

    /// Returns (status, affectedPages, reviewTermTexts): the winning fold
    /// bucket's page list, 0-based for the UI's tappable page chips (the
    /// message text keeps its 1-based numbering), and the display-only term
    /// texts behind an `.attention` verdict (nil for every other status —
    /// Layer 3's shape). A clean PASS carries nil for both.
    private func runLayer2OCR(
        _ doc: PDFDocument,
        pipelineMode: PipelineMode,
        regions: [Int: [RedactionRegion]],
        sensitiveTerms: [SensitiveTerm],
        perPageModes: [PipelineMode]
    ) async throws -> (VerificationStatus, [Int]?, [String]?, Bool) {
        // Entry-level cooperative cancellation, plus a
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
        // Term texts behind each `.sensitiveTermOutsideRegions` page, keyed
        // by 1-based page; read only by the fold's ATTENTION arm.
        var reviewTermsByPage: [Int: [String]] = [:]

        var pageIndex = 0
        while pageIndex < pageCount {
            try Task.checkCancellation()
            let chunkEnd = min(pageIndex + Self.ocrParallelism, pageCount)

            // Phase 1 — sequential extraction on this task. A page with no
            // extractable image is bucketed `.unchecked` here and never enters the
            // OCR group. A page PDFKit cannot open (or with no CGPDFPage
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

                // Identity contract (C-B binding): Vision's
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

                // Scope against the SAME region set the fill path used.
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
                    of: PageOCRResult.self
                ) { group in
                    for work in chunkWork {
                        group.addTask {
                            // Per-page cooperative cancellation inside the
                            // group body — the discipline the sequential loop kept
                            // at the top of each iteration now lives here.
                            try Task.checkCancellation()
                            return try await Self.classifyPageImages(
                                work,
                                sensitiveTerms: sensitiveTerms)
                        }
                    }
                    var acc: [PageOCRResult] = []
                    for try await result in group { acc.append(result) }
                    return acc
                }
                for result in chunkResults {
                    pageOutcomes.append(result.outcome)
                    if !result.reviewTermTexts.isEmpty {
                        reviewTermsByPage[result.outcome.page] = result.reviewTermTexts
                    }
                }
            }

            pageIndex = chunkEnd
        }

        return Self.foldLayer2PageOutcomes(
            pageOutcomes,
            pipelineMode: pipelineMode,
            documentHasRegions: documentHasRegions,
            reviewTermsByPage: reviewTermsByPage)
    }

    /// Cross-page fold: collapses the per-page Layer-2 buckets into the layer's
    /// single (status, pageReferences, reviewTermTexts, couldNotVerify)
    /// verdict — the fourth element is true for the two WARN arms that say
    /// the check did not fully run (unmappable coordinates, unchecked
    /// pages) and false for every note. `static` and
    /// OCR-free so arm precedence has a direct unit test
    /// (`Layer2FoldOrderTests`); `runLayer2OCR` feeds it the real buckets.
    /// `reviewTermsByPage` (1-based) carries the term texts behind each
    /// `.sensitiveTermOutsideRegions` page and is read only by the ATTENTION
    /// arm; every other arm returns nil for the third element.
    static func foldLayer2PageOutcomes(
        _ pageOutcomes: [PageOutcome],
        pipelineMode: PipelineMode,
        documentHasRegions: Bool,
        reviewTermsByPage: [Int: [String]] = [:]
    ) -> (VerificationStatus, [Int]?, [String]?, Bool) {
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
        let pagesWithSensitiveTermOutsideRegions = pages(in: .sensitiveTermOutsideRegions)
        let pagesWithFillArtifactInRegion = pages(in: .fillArtifactInRegion)
        let pagesWithTextOutsideRegionsOnly = pages(in: .textOutsideRegionsOnly)
        let pagesWithUnmappableImages = pages(in: .unmappable)
        let uncheckedPages = pages(in: .unchecked)

        // Page numbers only, never document content, in any message.
        // Priority fold: FAIL (term in region) > FAIL/WARN (text in region, by
        // the page's own mode) > ATTENTION (a redacted term readable outside
        // every region) > WARN (unmappable) > INFO (Part A fill artifact in
        // region) > INFO (text only outside regions) > unchecked WARN > PASS.
        // The layer reports its single most specific outcome. ATTENTION sits
        // above the WARN tier because the report aggregate ranks attention
        // above warn (`aggregateStatus`): a document carrying both a
        // term-outside page and an unmappable page reports the attention,
        // exactly as a FAIL page masks every lower arm. The warnable
        // unmappable arm stays ahead of the proven-artifact note — on a
        // multi-signal document a page in a warnable bucket sets the
        // masthead, not the note. Within the note tier the order stays
        // specificity (fill artifact > generic outside text); the unchecked
        // arm keeps its long-standing position below the expected-state
        // notes.
        if !pagesWithSensitiveTermInRegion.isEmpty {
            let list = pagesWithSensitiveTermInRegion.map(String.init).joined(separator: ", ")
            // An OCR hit inside a redacted region means readable text inside the
            // black box — a leak in EITHER mode. Region scoping already
            // excludes Searchable Redaction's expected surviving text.
            return (.fail("Sensitive text detected within a redacted region on \(pagePhrase(pagesWithSensitiveTermInRegion, list: list))"),
                    pagesWithSensitiveTermInRegion.map { $0 - 1 }, nil, false)
        }
        // On a rasterized page the region is a destroyed-pixel box that
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
                    pagesWithTextInRegionSecureRaster.map { $0 - 1 }, nil, false)
        }
        if !pagesWithTextInRegionSearchable.isEmpty {
            let list = pagesWithTextInRegionSearchable.map(String.init).joined(separator: ", ")
            return (.warn("OCR detected text within a redacted region on \(pagePhrase(pagesWithTextInRegionSearchable, list: list))"),
                    pagesWithTextInRegionSearchable.map { $0 - 1 }, nil, false)
        }
        // A term the user redacted is still readable outside every region —
        // read by OCR off the rendered page, so it is reported on BOTH page
        // modes (on a rasterized page Layer 2 is the only layer that can see
        // it; on a Searchable page Layers 3/10 read the same text and the
        // results masthead names each text once). The message is
        // mechanism-only and content-free; the term texts ride the third
        // element for the results row, in page order, deduplicated across
        // pages. The remedy is the user's — a text search — so the tier is
        // attention, never a FAIL: the redacted output itself is intact.
        if !pagesWithSensitiveTermOutsideRegions.isEmpty {
            let list = pagesWithSensitiveTermOutsideRegions.map(String.init).joined(separator: ", ")
            var seen = Set<String>()
            var reviewTerms: [String] = []
            for page in pagesWithSensitiveTermOutsideRegions {
                for text in reviewTermsByPage[page] ?? [] where seen.insert(text).inserted {
                    reviewTerms.append(text)
                }
            }
            return (.attention("Text matching your redactions is still readable on \(pagePhrase(pagesWithSensitiveTermOutsideRegions, list: list)) — read by OCR outside every redacted region"),
                    pagesWithSensitiveTermOutsideRegions.map { $0 - 1 },
                    reviewTerms.isEmpty ? nil : reviewTerms, false)
        }
        // Unmappable-coordinate pages (multi-image or padded thumbnail)
        // that carry OCR text near a region — surfaced as a WARN because the
        // identity check that would FAIL/PASS them is unsound.
        if !pagesWithUnmappableImages.isEmpty {
            let list = pagesWithUnmappableImages.map(String.init).joined(separator: ", ")
            return (.warn("OCR coordinates could not be mapped to page space on \(pagePhrase(pagesWithUnmappableImages, list: list)) — text could not be confirmed inside or outside a redacted region"),
                    pagesWithUnmappableImages.map { $0 - 1 }, nil, true)
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
                    pagesWithFillArtifactInRegion.map { $0 - 1 }, nil, false)
        }
        if !pagesWithTextOutsideRegionsOnly.isEmpty {
            let list = pagesWithTextOutsideRegionsOnly.map(String.init).joined(separator: ", ")
            switch pipelineMode {
            case .searchableRedaction:
                // Selectable/raster text outside regions is expected on a Searchable page.
                return (.info("OCR detected text on \(pagePhrase(pagesWithTextOutsideRegionsOnly, list: list)) — expected for Searchable Redaction mode."),
                        pagesWithTextOutsideRegionsOnly.map { $0 - 1 }, nil, false)
            case .secureRasterization:
                // Out-of-region OCR text on a Secure-Rasterized page is expected
                // output — nearly every real document keeps readable non-redacted
                // content, so as a WARN this arm fired on virtually every run and
                // pinned the masthead off green, drowning the conditional warns
                // (unmappable, unchecked, could-not-read) that DO carry signal.
                // The displaced-fill leak this WARN was originally aimed at is
                // carried by the in-region arms above (a displaced fill leaves
                // the region's own text readable in-region → FAIL); a redacted
                // term surviving out-of-region is the ATTENTION arm above.
                // This note covers the page's own un-redacted content only.
                // Expected-under-this-mode observations are informational;
                // every could-not-verify condition keeps its warning tier.
                // Pages with NO regions have nothing to violate → the raster's
                // own content → PASS.
                if documentHasRegions {
                    return (.info("Unredacted page content remains readable on \(pagePhrase(pagesWithTextOutsideRegionsOnly, list: list)) — expected for this mode."),
                            pagesWithTextOutsideRegionsOnly.map { $0 - 1 }, nil, false)
                }
            }
        }
        if !uncheckedPages.isEmpty {
            return (.warn("OCR could not be run on \(pageCountPhrase(uncheckedPages.count))"),
                    uncheckedPages.map { $0 - 1 }, nil, true)
        }
        return (.pass, nil, nil, false)
    }

    // MARK: - Layer 3: Binary String Search

    /// Returns (status, affectedPages, reviewTermTexts). The
    /// decoded-page hits and the EXIF WARN carry their 0-based page lists
    /// for the UI's tappable page chips; the structural raw-byte pass is
    /// document-level (nil). The third element carries the display-only term
    /// texts behind an `.attention` verdict (nil for every other status).
    private func runLayer3BinarySearch(
        _ doc: PDFDocument, sensitiveTerms: [SensitiveTerm]
    ) throws -> (VerificationStatus, [Int]?, [String]?, Bool) {
        // Entry-level cooperative cancellation.
        try Task.checkCancellation()
        // No terms provided — expected for manual-only redaction.
        // INFO, not PASS — the string search did not run, and "No issues
        // found" would overstate what this layer observed. INFO lands in the
        // notes group without bumping the masthead (Layer-7 boundary-count
        // precedent).
        guard !sensitiveTerms.isEmpty else {
            return (.info("No sensitive terms were provided — string search did not run."), nil, nil, false)
        }
        // Filter terms too short to search (shared
        // `AhoCorasick.isSearchableTerm`): ≥3 scalars (supports 3-letter PII
        // abbreviations like SSN, DOB, PHI) or a 2-character CJK name.
        let validTerms = sensitiveTerms.filter { AhoCorasick.isSearchableTerm($0.text) }
        guard !validTerms.isEmpty else {
            return (.warn("All sensitive terms shorter than 3 characters"), nil, nil, true)
        }
        // Surfaced on the otherwise-clean path below so a partial drop is
        // never silent (the all-short WARN above covers the total drop).
        let droppedTermCount = sensitiveTerms.count - validTerms.count

        // Build the Aho-Corasick automaton with all encoding variants, keeping
        // each pattern's token-boundary discipline for the match
        // post-filters below.
        // DEFERRED: automaton caching is deferred to
        // V1.1. AhoCorasick is a Sendable value built fresh per
        // verification call; caching needs an actor/class wrapper for ~25 ms
        // saved once per export — low benefit, no security relevance.
        let termAutomaton = SensitiveTermAutomaton(validTerms: validTerms)
        guard termAutomaton.hasPatterns else { return (.pass, nil, nil, false) }
        let automaton = termAutomaton.automaton

        // If the automaton degraded due to pattern size limits,
        // report the limitation rather than silently passing.
        if automaton.isDegraded {
            return (.warn("Sensitive term search exceeded size limit — results may be incomplete"), nil, nil, true)
        }

        // Get raw PDF bytes.
        // Memory-mapped access via
        // `Data(contentsOf:options:.mappedIfSafe)`; loadPDFData uses the
        // default-options overload, which is `.mappedIfSafe`.
        guard let (data, cgDoc) = loadPDFData(doc) else {
            return (.warn("Could not read output PDF for binary search"), nil, nil, true)
        }

        // First WARN encountered, returned only if no FAIL is found below: a
        // non-boundary structural fragment (Part A) or an EXIF hit (Part B) must
        // not mask a boundary-token or decoded-text FAIL. Carries the 0-based page
        // list when the WARN is page-scoped (EXIF); nil when document-level.
        var deferredWarn: (message: String, pages: [Int]?)?
        // Structural complete-token FAIL, held (not returned) so the
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
        // output embeds no compressed PII-bearing streams, and the
        // page.string re-scan below compensates for PDFKit-decoded text.
        // Boundary-required terms drop matches embedded in an
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

        // M1 tightening: always re-scan PDFKit's decoded
        // page.string, even when the structural raw-byte pass produced no
        // matches. PDFKit decodes operator-level encodings transparently
        // (UTF-16 surrogate halves, octal escapes inside literal strings,
        // Name-object substitution); sensitive terms that live only inside
        // an excluded stream range or behind a decoding transformation
        // surface here.
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
            // The decoded text is scanned as extracted and, when the search
            // path's normalizer changes it (a ligature or another
            // compatibility form in the text layer), in that normalized form
            // as well, so a residue the search can locate is never invisible
            // here. A page counts once; its instance count is the larger of
            // the two scans, so one occurrence never double-counts.
            let decodedMatches = termAutomaton.tokenFilteredMatches(in: Data(pageText.utf8))
            let normalizedText = TextNormalizer.normalize(pageText)
            let normalizedMatches = normalizedText == pageText
                ? []
                : termAutomaton.tokenFilteredMatches(in: Data(normalizedText.utf8))
            if !decodedMatches.isEmpty || !normalizedMatches.isEmpty {
                decodedHitPages.append(i)
                decodedMatchCount += max(
                    AhoCorasick.uniqueOccurrenceCount(decodedMatches),
                    AhoCorasick.uniqueOccurrenceCount(normalizedMatches))
                for text in termAutomaton.matchedTermTexts(decodedMatches + normalizedMatches)
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
        // display (the message itself stays content-free).
        if let structuralFailMessage {
            let message = [structuralFailMessage, decodedResidualMessage]
                .compactMap { $0 }
                .joined(separator: "; ")
            return (.fail(message), decodedHitPages.isEmpty ? nil : decodedHitPages, nil, false)
        }
        if let decodedResidualMessage {
            return (.attention(decodedResidualMessage), decodedHitPages, decodedTermTexts, false)
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

        if let warn = deferredWarn { return (.warn(warn.message), warn.pages, nil, false) }
        if droppedTermCount > 0 {
            // Partial-coverage honesty: some (not all) terms were too short
            // to search. Informational — the searched terms were clean.
            return (.info(shortTermTail(droppedTermCount)), nil, nil, false)
        }
        return (.pass, nil, nil, false)
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

    // MARK: - Layer 4: Structural Verification

    /// Returns (status, affectedPages) where affectedPages is non-nil
    /// only for per-page /AA findings (enables tappable page chips in UI).
    private func runLayer4Structural(_ doc: PDFDocument) throws -> (VerificationStatus, [Int]?, Bool) {
        // Entry-level cooperative cancellation.
        try Task.checkCancellation()
        guard let (pdfData, cgDoc) = loadPDFData(doc),
              let catalog = cgDoc.catalog else {
            return (.warn("Could not inspect document structure"), nil, true)
        }

        // FAIL-triggering keys
        // Keys that indicate active content or encryption in the
        // document catalog. /AA triggers automatic actions (can execute JS on
        // open/close/print). /Encrypt should never appear in redacted output.
        // /RichMedia and /Flash can embed content containing PII.
        let failKeys = ["JavaScript", "JS", "OpenAction", "Launch",
                        "EmbeddedFiles", "SubmitForm", "ResetForm", "AcroForm",
                        "AA", "Encrypt", "RichMedia", "Flash"]
        for key in failKeys {
            var obj: CGPDFObjectRef?
            if CGPDFDictionaryGetObject(catalog, key, &obj) {
                return (.fail("\(key) found in document catalog"), nil, false)
            }
        }

        // The standard real-world carrier for embedded files and
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
                    return (.fail("\(key) found under /Names in document catalog"), nil, false)
                }
            }
        }

        // Check per-page /AA entries. Page-level automatic actions
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
            return (.fail("Per-page /AA (automatic action) found on \(pageCountPhrase(aaPages.count))"), aaPages, false)
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
        // pdfData already loaded by loadPDFData (memory-mapped).
        let eofMarker = "%%EOF".data(using: .ascii)!
        var eofCount = 0
        var searchRange = pdfData.startIndex..<pdfData.endIndex
        while let range = pdfData.range(of: eofMarker, options: [], in: searchRange) {
            eofCount += 1
            searchRange = range.upperBound..<pdfData.endIndex
        }
        if eofCount > 1 {
            // Incremental updates can append original content
            // after redaction. Resecta's reconstructor writes a single clean
            // PDF stream — multiple markers indicate tampering or corruption.
            return (.fail("Multiple %%EOF markers (\(eofCount)) — incremental update may contain original content"), nil, false)
        }

        if !warnings.isEmpty {
            return (.warn("Structural findings: \(warnings.joined(separator: ", "))"), nil, false)  // LegalPhrases:safe (the shipped message; a list of structural notes)
        }
        return (.pass, nil, false)
    }

    // MARK: - Layer 5: Metadata Verification

    private func runLayer5Metadata(_ doc: PDFDocument) throws -> (VerificationStatus, Bool) {
        // Entry-level cooperative cancellation.
        try Task.checkCancellation()
        guard let (pdfData, cgDoc) = loadPDFData(doc) else {
            return (.warn("Could not inspect metadata"), true)
        }

        // Scan for XMP metadata BEFORE the /Info guard. XMP lives in
        // the document's /Metadata stream, independent of /Info; the prior
        // early `return .pass` on a nil /Info dictionary skipped the XMP scan
        // entirely, so a document carrying XMP but no /Info passed silently.
        // pdfData already loaded by loadPDFData (memory-mapped).
        let hasXMP = pdfData.range(of: "<?xpacket".data(using: .ascii)!) != nil
            || pdfData.range(of: "<x:xmpmeta>".data(using: .ascii)!) != nil
            || pdfData.range(of: "<rdf:RDF".data(using: .ascii)!) != nil

        // Check /Info dictionary. When absent, the XMP scan above is still
        // authoritative — surface it rather than passing blind.
        guard let infoDict = cgDoc.info else {
            return (hasXMP
                ? .warn("Auto-injected metadata present: XMP metadata")
                : .pass, false)
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
        // Never include metadata values in status messages.
        let sensitiveKeys = ["Title", "Author", "Subject", "Keywords", "Creator"]
        for key in sensitiveKeys {
            var obj: CGPDFObjectRef?
            if CGPDFDictionaryGetObject(infoDict, key, &obj) {
                return (.fail("Metadata key /\(key) present"), false)
            }
        }

        // /Producer, /CreationDate, /ModDate are Apple auto-injected —
        // informational only; they ride in `infoFindings` so a clean
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

        // Check for /Trapped (can reveal document workflow)
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
            // Do not include key values — just names
            return (.fail("Non-standard /Info key(s): \(nonStandardKeys.joined(separator: ", "))"), false)
        }

        // Writer-field attestation. The writer rewrites the auto-injected
        // /Producer literal to `PDFStreamReconstructor.fixedProducerValue`
        // and the /CreationDate and /ModDate literals to
        // `PDFStreamReconstructor.fixedDateValue` after the context closes;
        // that rewrite leaves a literal untouched on any anomaly and only
        // logs. Read the three values back here so a silent no-op (or a
        // future writer change) is reported instead of passing as
        // auto-injected metadata. The producer rewrite pads with spaces
        // after the closing paren, so the decoded literal is the bare fixed
        // value; trailing spaces inside a literal are tolerated. A value
        // that does not decode counts as not rewritten. An absent key stays
        // on the paths below. One message covers all three fields; never
        // echo a value in it.
        let fixedWriterFields = [
            ("Producer", PDFStreamReconstructor.fixedProducerValue),
            ("CreationDate", PDFStreamReconstructor.fixedDateValue),
            ("ModDate", PDFStreamReconstructor.fixedDateValue),
        ]
        for (key, fixedValue) in fixedWriterFields {
            var ref: CGPDFStringRef?
            guard CGPDFDictionaryGetString(infoDict, key, &ref), let ref else { continue }
            var value = (CGPDFStringCopyTextString(ref) as String?) ?? ""
            while value.hasSuffix(" ") { value.removeLast() }
            if value != fixedValue {
                return (.warn("Producer or timestamp fields were not rewritten to the fixed values"), false)
            }
        }

        // File-identifier attestation. The writer rewrites both halves of
        // the trailer's `/ID` pair to the identifier derived from the
        // file's own bytes (`PDFFileIdentifier`); recompute it here and
        // report a pair that was not derived that way — after the fixed
        // fields, ahead of /Trapped and XMP, one message that never carries
        // a value. An absent pair stays on the paths below.
        if let idArray = cgDoc.fileIdentifier,
           !Self.fileIdentifierMatchesContents(idArray, pdfData: pdfData) {
            return (.warn("File identifier was not derived from the file contents"), false)
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
            return (.warn("\(prefix): \(warnings.joined(separator: ", "))"), false)
        }
        if !infoFindings.isEmpty {
            return (.info("Auto-injected metadata present: \(infoFindings.joined(separator: ", "))"), false)
        }
        return (.pass, false)
    }

    /// True when the two strings of a trailer `/ID` array both equal the
    /// identifier recomputed from `pdfData`. An array that is not two
    /// strings, or a pair the locator cannot read from the file's tail in
    /// the writer's shape, is by construction not the writer's derived
    /// value.
    static func fileIdentifierMatchesContents(_ idArray: CGPDFArrayRef, pdfData: Data) -> Bool {
        guard CGPDFArrayGetCount(idArray) == 2 else { return false }
        var halves: [Data] = []
        for index in 0..<2 {
            var ref: CGPDFStringRef?
            guard CGPDFArrayGetString(idArray, index, &ref), let ref,
                  let bytes = CGPDFStringGetBytePtr(ref) else { return false }
            halves.append(Data(bytes: bytes, count: CGPDFStringGetLength(ref)))
        }
        guard let expected = PDFFileIdentifier.recomputedIdentifier(for: pdfData) else { return false }
        return halves[0] == expected && halves[1] == expected
    }

    // MARK: - PDF Data Loading Helper

    /// Load raw PDF bytes and a CGPDFDocument from a PDFDocument.
    /// Prefers URL-based loading; the default-options `Data(contentsOf:)`
    /// is `.mappedIfSafe`.
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

    // MARK: - Per-page mode coverage (Layers 6–9)

    /// The 0-based pages `perPageModes` does not describe — every index at
    /// or beyond `perPageModes.count` — or nil when the array covers the
    /// whole document. The Searchable-layer dispatchers (Layers 6–9) pick
    /// their pages through `perPageModes[i]`, so a short array silently
    /// leaves the tail of the document out of the check; each dispatcher
    /// reports that tail as a WARN on its otherwise-PASS exit instead of
    /// passing pages it never looked at. FAIL, `.skipped` and the layer's
    /// own WARNs keep precedence. The coordinator always supplies one mode
    /// per page, so on the product's own paths this returns nil.
    private func perPageModeCoverageGap(
        perPageModes: [PipelineMode], pageCount: Int
    ) -> [Int]? {
        guard perPageModes.count < pageCount else { return nil }
        return Array(perPageModes.count..<pageCount)
    }

    /// WARN copy for a per-page mode coverage gap — the mechanism only.
    private func perPageModeCoverageWarn(
        uncovered: [Int], pageCount: Int
    ) -> VerificationStatus {
        let covered = pageCount - uncovered.count
        let unchecked = uncovered.count == 1
            ? "1 page was" : "\(uncovered.count) pages were"
        return .warn(
            "Per-page mode data covered \(covered) of \(pageCount) "
            + "\(pageCount == 1 ? "page" : "pages") — \(unchecked) not checked"
        )
    }

    // MARK: - Layer 6: Spatial Verification

    /// Dispatch spatial verification across all Searchable Redaction pages.
    /// Collects all failing pages for tappable navigation chips.
    /// A page declared Secure Rasterization is not position-checked, but it
    /// is probed for a text layer: image-only output must carry none (the
    /// writer draws no text on such a page), so a text layer there FAILs
    /// the layer outright — a tampered or foreign output, never a skip.
    ///
    /// When any region on the page carries `vertices`, the spatial
    /// exclusion check uses polygon-or-rect intersection (rect for
    /// vertex-less regions, even-odd polygon for vertex-bearing). The
    /// helper accepts `regionShapes` so the verifier can choose per-region.
    private func runLayer6SpatialVerification(
        _ doc: PDFDocument,
        regions: [Int: [RedactionRegion]],
        perPageModes: [PipelineMode],
        verifier: SandwichVerification
    ) async throws -> (VerificationStatus, [Int]?, Bool) {
        // Entry-level cooperative cancellation.
        try Task.checkCancellation()
        var failingPages: [Int] = []
        var firstFailMessage: String?
        // Pages declared Secure Rasterization that still carry a text
        // layer. Image-only output must carry none, so this FAIL outranks
        // every other outcome of the layer.
        var secureDeclaredTextPages: [Int] = []
        // Per-page WARNs from the exclusion pass (a positional edge graze,
        // or characters whose position could not be measured): fold below
        // FAIL and above the unreadable-page WARN, first message in page
        // order.
        var exclusionWarnPages: [Int] = []
        var firstExclusionWarnMessage: String?
        // The classification of that first WARN: true when the verifier
        // could not place characters (the unmeasured-position note), false
        // for a positional edge graze.
        var firstExclusionCouldNotVerify = false
        // Eligible pages PDFKit cannot open surface as a WARN when the
        // layer would otherwise PASS — see runLayer1TextExtraction.
        var unreadablePages: [Int] = []

        for i in 0..<doc.pageCount {
            try Task.checkCancellation()
            // Pages beyond `perPageModes` are reported by the coverage arm
            // below. A page declared Secure Rasterization is probed for a
            // text layer — an image-only page must carry none — and is not
            // position-checked; the switch is exhaustive so a new mode
            // cannot be skipped silently.
            guard i < perPageModes.count else { continue }
            switch perPageModes[i] {
            case .secureRasterization:
                if let text = doc.page(at: i)?.string,
                   !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    secureDeclaredTextPages.append(i)
                }
                continue
            case .searchableRedaction:
                break
            }
            guard let page = doc.page(at: i) else {
                unreadablePages.append(i)
                continue
            }
            let pageRegions = regions[i] ?? []
            // Do NOT skip region-less pages. The empty pageRegions
            // flows through the maps below as regionShapes == [] into
            // verifySpatialExclusion, which (count-only guard) still runs the
            // origin-delta lattice — closing the glyph-position-tamper gap
            // on region-less searchable pages. Cost is bounded by the existing
            // 256-iteration cancellation cadence in the lattice walk.

            // Convert regions to output page coordinates (output pages
            // always have zero-origin bounds)
            let outputBounds = page.bounds(for: .cropBox)
            let rectsInPoints = pageRegions.map {
                normalizedToPDFPageCoordinates($0.normalizedRect, pageRect: outputBounds)
            }
            // Build polygon-aware shapes. Polygon vertices are
            // converted into PDF-point-space via the same conversion the
            // rect path uses. Rect-only regions carry `polygonVertices ==
            // nil`. `bounds` carries the un-expanded rect (the
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

            let outcome = try await verifier.spatialExclusionOutcome(
                outputPage: page,
                regionShapes: regionShapes,
                pageIndex: i
            )
            if case .fail(let msg) = outcome.status {
                failingPages.append(i)
                if firstFailMessage == nil { firstFailMessage = msg }
            } else if case .warn(let msg) = outcome.status {
                exclusionWarnPages.append(i)
                if firstExclusionWarnMessage == nil {
                    firstExclusionWarnMessage = msg
                    firstExclusionCouldNotVerify = outcome.couldNotVerify
                }
            }
        }
        // A text layer on a page written as image-only outranks every other
        // outcome: the page was declared to carry none.
        if !secureDeclaredTextPages.isEmpty {
            let list = secureDeclaredTextPages.map { String($0 + 1) }.joined(separator: ", ")
            return (.fail("A page written as image-only still carries a text layer on \(pagePhrase(secureDeclaredTextPages, list: list))"),
                    secureDeclaredTextPages, false)
        }
        if let msg = firstFailMessage {
            return (.fail(msg), failingPages, false)
        }
        // The exclusion pass's WARN outranks the unreadable-page WARN
        // (mirror of FAIL's masking above; the combined case is rare and the
        // exclusion message is the more actionable of the two).
        if let msg = firstExclusionWarnMessage {
            return (.warn(msg), exclusionWarnPages, firstExclusionCouldNotVerify)
        }
        if !unreadablePages.isEmpty {
            return (unreadablePagesWarn(unreadablePages), unreadablePages, true)
        }
        // Pages beyond `perPageModes` were never selected above — report
        // them rather than pass them (see perPageModeCoverageGap).
        if let uncovered = perPageModeCoverageGap(
            perPageModes: perPageModes, pageCount: doc.pageCount
        ) {
            return (perPageModeCoverageWarn(
                uncovered: uncovered, pageCount: doc.pageCount), uncovered, true)
        }
        return (.pass, nil, false)
    }

    // MARK: - Layer 7: Character Count Cross-Check

    /// Dispatch character count verification across all Searchable Redaction pages.
    /// Collects all failing pages for tappable navigation chips.
    private func runLayer7CharacterCount(
        _ doc: PDFDocument,
        filterDigests: [PageFilterDigest?],
        perPageModes: [PipelineMode],
        verifier: SandwichVerification
    ) async throws -> (VerificationStatus, [Int]?, Bool) {
        // Entry-level cooperative cancellation.
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
            return (.fail(msg), failingPages, false)
        }
        // Eligible-but-unchecked → honest .skipped (the verify-only
        // resume path rebuilds all-nil digests). Partial coverage → .warn
        // (defensive; unreachable today since digests are all-present or
        // all-nil). eligible == 0 stays .pass when `perPageModes` covers the
        // document — skipped by design (every page is per-page Secure
        // Rasterization); promoting it would WARN-flag valid docs (the
        // false-positive trap one layer up). Pages beyond `perPageModes`
        // never counted as eligible, so they are reported last, on the
        // otherwise-PASS exit (see perPageModeCoverageGap).
        if eligible > 0 && checked == 0 {
            return (.skipped, nil, false)
        }
        if checked < eligible {
            return (.warn("Cross-checked \(checked) of \(eligible) \(eligible == 1 ? "page" : "pages") — remaining pages lacked rasterization data"), nil, true)
        }
        if let uncovered = perPageModeCoverageGap(
            perPageModes: perPageModes, pageCount: doc.pageCount
        ) {
            return (perPageModeCoverageWarn(
                uncovered: uncovered, pageCount: doc.pageCount), uncovered, true)
        }
        return (.pass, nil, false)
    }

    // MARK: - Layer 8: Font Verification

    /// Dispatch font verification across all Searchable Redaction pages.
    /// Collects all failing pages for tappable navigation chips.
    private func runLayer8FontVerification(
        _ doc: PDFDocument,
        perPageModes: [PipelineMode],
        verifier: SandwichVerification
    ) async throws -> (VerificationStatus, [Int]?, Bool) {
        // Entry-level cooperative cancellation.
        try Task.checkCancellation()
        var failingPages: [Int] = []
        var firstFailMessage: String?
        // See runLayer1TextExtraction — unreadable eligible pages WARN
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
            return (.fail(msg), failingPages, false)
        }
        if !unreadablePages.isEmpty {
            return (unreadablePagesWarn(unreadablePages), unreadablePages, true)
        }
        // Pages beyond `perPageModes` were never selected above — report
        // them rather than pass them (see perPageModeCoverageGap).
        if let uncovered = perPageModeCoverageGap(
            perPageModes: perPageModes, pageCount: doc.pageCount
        ) {
            return (perPageModeCoverageWarn(
                uncovered: uncovered, pageCount: doc.pageCount), uncovered, true)
        }
        return (.pass, nil, false)
    }

    // MARK: - Layer 9: Character Lineage

    /// Dispatch character-lineage verification across all Searchable Redaction
    /// pages. Re-computes the SHA-256 over output composed-character iteration
    /// and reports mismatch against `PageFilterDigest.lineageHash`. Reorderings,
    /// insertions, deletions, and replacements of non-zero-bounds composed
    /// characters between filter and final PDF flip the hash. Zero-width
    /// insertions do NOT — both sides iterate non-zero-bounds composed
    /// characters only (pinned M4 residual; term-bearing injections are
    /// covered by Layers 3 and 10). See
    /// `SandwichVerification.verifyCharacterLineage`.
    private func runLayer9CharacterLineage(
        _ doc: PDFDocument,
        filterDigests: [PageFilterDigest?],
        perPageModes: [PipelineMode],
        verifier: SandwichVerification
    ) async throws -> (VerificationStatus, [Int]?, Bool) {
        // Entry-level cooperative cancellation +
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
            return (.fail(msg), failingPages, false)
        }
        // Eligible-but-unchecked → .skipped; partial → .warn;
        // eligible == 0 stays .pass (skipped by design); pages beyond
        // `perPageModes` are reported last. See Layer 7.
        if eligible > 0 && checked == 0 {
            return (.skipped, nil, false)
        }
        if checked < eligible {
            return (.warn("Cross-checked \(checked) of \(eligible) \(eligible == 1 ? "page" : "pages") — remaining pages lacked rasterization data"), nil, true)
        }
        if let uncovered = perPageModeCoverageGap(
            perPageModes: perPageModes, pageCount: doc.pageCount
        ) {
            return (perPageModeCoverageWarn(
                uncovered: uncovered, pageCount: doc.pageCount), uncovered, true)
        }
        return (.pass, nil, false)
    }
}

// Grammatical page phrases, wording only. The prior
// "on 1 page(s): 1" form both dodged the plural and repeated the count
// as the list. Verdict levels and thresholds at every call site are
// untouched.
func pagePhrase(_ pages: [Int], list: String) -> String {
    pages.count == 1 ? "page \(list)" : "\(pages.count) pages: \(list)"
}

private func pageCountPhrase(_ count: Int) -> String {
    count == 1 ? "1 page" : "\(count) pages"
}

/// WARN copy for pages a per-page layer loop could not open
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
