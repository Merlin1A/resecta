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
// runs seven checks, Searchable Redaction twelve; the two post-sequential
// checks are last in both), never from an index table.

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

    /// Layer-2 OCR downsample cap (largest pixel dimension), a 4096-px
    /// ceiling: the OCR check looks for READABLE
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
    var onRunLayerDispatch: (@Sendable (Int, ObjectIdentifier) -> Void)?

    /// Canonical per-mode layer order: every `VerificationLayer` that applies
    /// to `mode`, in declaration order (`searchRecheck` last in both modes).
    /// Counts, ordinals and the coordinator's schedule derive from this list.
    public func layers(for mode: PipelineMode) -> [VerificationLayer] {
        VerificationLayer.allCases.filter { $0.appliesTo(mode) }
    }

    /// Run a single verification layer. `appliedSearches` feeds the two
    /// post-sequential checks only (every other layer ignores it): the typed
    /// requests the Search Re-check, the scan requests the Detection Sweep;
    /// empty ⇒ that layer reports INFO. Called on its own, each of those two
    /// runs its own pass over the output; the orchestrator runs ONE pass for
    /// both and hands it in through the internal overload.
    /// `manualRegionsWithoutText` (manual regions on pages with no text
    /// layer to read) is Layer 3's alone: its clean line names them.
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
        appliedSearches: [SearchRecheckRequest] = [],
        manualRegionsWithoutText: Int = 0
    ) async -> LayerResult {
        await runLayer(
            layer, outputDocument: outputDocument, sourcePageCount: sourcePageCount,
            regions: regions, sensitiveTerms: sensitiveTerms, pipelineMode: pipelineMode,
            filterDigests: filterDigests, perPageModes: perPageModes,
            appliedSearches: appliedSearches, manualRegionsWithoutText: manualRegionsWithoutText,
            batch: nil)
    }

    /// The layer template behind `runLayer`: `batch` is the orchestrator's
    /// shared output pass for the post-sequential checks (nil ⇒ the layer
    /// runs its own); its wall-clock is added to the row's duration.
    @concurrent
    func runLayer(
        _ layer: VerificationLayer,
        outputDocument: SendablePDFDocument,
        sourcePageCount: Int,
        regions: [Int: [RedactionRegion]],
        sensitiveTerms: [SensitiveTerm],
        pipelineMode: PipelineMode,
        filterDigests: [PageFilterDigest?],
        perPageModes: [PipelineMode],
        appliedSearches: [SearchRecheckRequest],
        manualRegionsWithoutText: Int,
        batch: PostSequentialBatch?
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
        // A layer that supplies its own copy (the two post-sequential
        // checks; Layers 2 and 5 for a PASS that read something and reports
        // nothing; the Layer-7 promotion below is the precedent).
        var copyOverride: LayerCopy? = nil
        // Display-only per-query lines (the two post-sequential checks only).
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
                let (s1, pages1, terms1, cnv1, copy1) = try await runLayer2OCR(
                    doc, pipelineMode: pipelineMode,
                    regions: regions, sensitiveTerms: sensitiveTerms,
                    perPageModes: perPageModes)
                status = s1
                layerPageReferences = pages1
                layerReviewTerms = terms1
                couldNotVerify = cnv1
                copyOverride = copy1
            case .binaryStringSearch:
                let (s2, pages2, terms2, cnv2) = try runLayer3BinarySearch(doc, sensitiveTerms: sensitiveTerms)
                status = s2
                layerPageReferences = pages2
                layerReviewTerms = terms2
                couldNotVerify = cnv2
                // Manual regions on pages with no text layer: the clean line gains one sentence.
                copyOverride = Self.manualRegionsWithoutTextCopy(status, count: manualRegionsWithoutText)
            case .structureCheck:
                let (s, pages, cnv3) = try runLayer4Structural(doc)
                status = s
                layerPageReferences = pages
                couldNotVerify = cnv3
            case .metadataCheck:
                let (s4, cnv4, copy4) = try runLayer5Metadata(doc)
                status = s4
                couldNotVerify = cnv4
                copyOverride = copy4
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
                // Search Re-check — re-runs every applied typed search on
                // the output through the search engine itself (text layer
                // or the searcher's own OCR path per page). Supplies its own
                // PASS/ATTENTION/WARN copy; INFO when nothing was applied.
                let outcome = try await SearchRecheck().run(
                    outputDocument: outputDocument,
                    requests: appliedSearches,
                    observations: batch?.observations
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
            case .detectionSweep:
                // Detection Sweep — re-runs the applied scan on the output
                // through the detectors, minus the items left unselected,
                // and every detector for anything further. Supplies its own
                // PASS/INFO/WARN copy; never ATTENTION; INFO when no scan
                // was applied and no sweep requested.
                let outcome = try await DetectionSweep().run(
                    outputDocument: outputDocument,
                    requests: appliedSearches,
                    observations: batch?.observations
                )
                status = outcome.status
                layerPageReferences = outcome.pageReferences
                layerReviewTerms = outcome.reviewTermTexts
                copyOverride = outcome.copyOverride
                layerQueryLines = outcome.queryLines
                // The sweep's only WARN family is the same unchecked-pages
                // one: a WARN here always says the sweep did not fully run.
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

        let duration = CFAbsoluteTimeGetCurrent() - start + (batch?.seconds ?? 0)
        let name = layer.name
        let symbol = layer.symbolName

        // The short line is the row; the detail line is EMPTY unless the
        // check has something to add to it (`LayerResult.hasDetail`). The
        // status message already says what the check saw, so no arm
        // restates it behind the layer name. The skipped arm keeps its
        // sentence: it adds the why.
        var shortDesc: String
        var detailDesc: String
        switch status {
        case .pass:
            shortDesc = "No issues found."
            detailDesc = ""
        case .warn(let msg), .info(let msg), .attention(let msg), .fail(let msg):
            shortDesc = msg
            detailDesc = ""
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
                // The short line carries the count; nothing to add.
                shortDesc = "\(totalBoundary) character\(totalBoundary == 1 ? "" : "s") near redaction boundaries."
                detailDesc = ""
                status = .info(shortDesc)
            }
        }

        // A layer-supplied copy replaces the generic composition for the
        // status it was composed for (PASS / INFO / ATTENTION / WARN); FAIL
        // and skipped always use the generic lines.
        if let copyOverride, status == .pass || status.isInfo || status.isAttention || status.isWarn {
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
    /// The ranking over every status: any FAIL → overall FAIL, with the
    /// first FAIL's own message. Else any ATTENTION → overall ATTENTION
    /// (un-redacted residual text — user-recoverable, so it outranks notes
    /// but never masks an output defect). Else any WARN → overall WARN.
    /// Else the skipped accounting below. INFO rows and PASS rows rank
    /// alike: all of them → overall PASS. One exhaustive switch classifies
    /// each layer, so a new status case is a compile error here, not a
    /// silent PASS.
    public func aggregateStatus(_ layers: [LayerResult]) -> VerificationStatus {
        var firstFail: String?
        var firstAttention: String?
        var firstWarn: String?
        var skippedCount = 0
        for layer in layers {
            switch layer.status {
            case .fail(let msg):
                if firstFail == nil { firstFail = msg }
            case .attention(let msg):
                if firstAttention == nil { firstAttention = msg }
            case .warn(let msg):
                if firstWarn == nil { firstWarn = msg }
            case .skipped:
                skippedCount += 1
            case .info, .pass:
                break
            }
        }
        if let msg = firstFail { return .fail(msg) }
        if let msg = firstAttention { return .attention(msg) }
        if let msg = firstWarn { return .warn(msg) }
        // Account for .skipped layers so a
        // partially- or wholly-skipped verdict is not reported as PASS. All
        // layers skipped → .skipped (preserves the VerificationReport.skipped
        // sentinel); some but not all skipped → .warn. Count-agnostic — never
        // assumes a 5- or 10-layer total.
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

    // MARK: - PDF Data Loading Helper

    /// Load raw PDF bytes and a CGPDFDocument from a PDFDocument.
    /// Prefers URL-based loading; reads the file with default options (no
    /// mapping requested).
    /// Falls back to dataRepresentation() for non-file documents.
    func loadPDFData(_ doc: PDFDocument) -> (Data, CGPDFDocument)? {
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
}

// Grammatical page phrases, wording only. The prior
// "on 1 page(s): 1" form both dodged the plural and repeated the count
// as the list. Verdict levels and thresholds at every call site are
// untouched.
func pagePhrase(_ pages: [Int], list: String) -> String {
    pages.count == 1 ? "page \(list)" : "\(pages.count) pages: \(list)"
}

func pageCountPhrase(_ count: Int) -> String {
    count == 1 ? "1 page" : "\(count) pages"
}

/// WARN copy for pages a per-page layer loop could not open
/// (Layers 1/6/8), mirroring Layer 10's per-page unavailability shape.
/// `pages` are 0-based (the UI chip convention); the copy prints 1-based
/// numbers — a single page by number, multiple as count + list.
func unreadablePagesWarn(_ pages: [Int]) -> VerificationStatus {
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
