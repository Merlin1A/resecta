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
    var onRunLayerDispatch: (@Sendable (Int, ObjectIdentifier) -> Void)?

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

    /// Run a single verification layer. `appliedSearches` feeds the two
    /// post-sequential checks only (every other layer ignores it): the typed
    /// requests the Search Re-check, the scan requests the Detection Sweep;
    /// empty ⇒ that layer reports INFO. Called on its own, each of those two
    /// runs its own pass over the output; the orchestrator runs ONE pass for
    /// both and hands it in through the internal overload.
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
        await runLayer(
            layer, outputDocument: outputDocument, sourcePageCount: sourcePageCount,
            regions: regions, sensitiveTerms: sensitiveTerms, pipelineMode: pipelineMode,
            filterDigests: filterDigests, perPageModes: perPageModes,
            appliedSearches: appliedSearches, batch: nil)
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

    // MARK: - Layer 4: Structural Verification

    /// Returns (status, affectedPages) where affectedPages is non-nil
    /// only for per-page /AA findings (enables tappable page chips in UI).
    private func runLayer4Structural(_ doc: PDFDocument) throws -> (VerificationStatus, [Int]?, Bool) {
        // Entry-level cooperative cancellation.
        try Task.checkCancellation()
        let loaded = loadPDFData(doc)
        // /Encrypt is a trailer key, never the catalog's: an encrypted output FAILs, locked or not.
        if let cgDoc = loaded?.1, cgDoc.isEncrypted { return (.fail("Encrypt found in document"), nil, false) }
        guard let (pdfData, cgDoc) = loaded, let catalog = cgDoc.catalog else {
            return (.warn("Could not inspect document structure"), nil, true)
        }

        // FAIL-triggering keys: active content in the document catalog. /AA
        // triggers automatic actions (can execute JS on open/close/print);
        // /RichMedia and /Flash can embed content containing PII.
        let failKeys = ["JavaScript", "JS", "OpenAction", "Launch",
                        "EmbeddedFiles", "SubmitForm", "ResetForm", "AcroForm",
                        "AA", "RichMedia", "Flash"]
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
        // pdfData already read into memory by loadPDFData.
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

    /// The fixed-fields PASS detail: the writer's own values, nothing of the
    /// file's, are what the /Info dictionary carries.
    static let layer5FixedFieldsDetail =
        "Producer and timestamps carry the writer's fixed values; no file-specific metadata is present."

    private func runLayer5Metadata(_ doc: PDFDocument) throws -> (VerificationStatus, Bool, LayerCopy?) {
        // Entry-level cooperative cancellation.
        try Task.checkCancellation()
        guard let (pdfData, cgDoc) = loadPDFData(doc) else {
            return (.warn("Could not inspect metadata"), true, nil)
        }

        // Scan for XMP metadata BEFORE the /Info guard. XMP lives in
        // the document's /Metadata stream, independent of /Info; the prior
        // early `return .pass` on a nil /Info dictionary skipped the XMP scan
        // entirely, so a document carrying XMP but no /Info passed silently.
        // pdfData already read into memory by loadPDFData.
        let hasXMP = pdfData.range(of: "<?xpacket".data(using: .ascii)!) != nil
            || pdfData.range(of: "<x:xmpmeta>".data(using: .ascii)!) != nil
            || pdfData.range(of: "<rdf:RDF".data(using: .ascii)!) != nil

        // Check /Info dictionary. When absent, the XMP scan above is still
        // authoritative — surface it rather than passing blind.
        guard let infoDict = cgDoc.info else {
            return (hasXMP
                ? .warn("Auto-injected metadata present: XMP metadata")
                : .pass, false, nil)
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
                return (.fail("Metadata key /\(key) present"), false, nil)
            }
        }

        // /Producer, /CreationDate, /ModDate are Apple auto-injected and
        // rewritten to the writer's fixed values (attested below); they
        // ride in `infoFindings` so a clean doc with only these is a PASS
        // whose detail says so.
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
            return (.fail("Non-standard /Info key(s): \(nonStandardKeys.joined(separator: ", "))"), false, nil)
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
                return (.warn("Producer or timestamp fields were not rewritten to the fixed values"), false, nil)
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
            return (.warn("File identifier was not derived from the file contents"), false, nil)
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
            return (.warn("\(prefix): \(warnings.joined(separator: ", "))"), false, nil)
        }
        if !infoFindings.isEmpty {
            // The three keys are always present by construction and were
            // attested above: a PASS that says what it read, never a note.
            return (.pass, false, LayerCopy(short: "No issues found.", detail: Self.layer5FixedFieldsDetail))
        }
        return (.pass, false, nil)
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
        // Per-page WARNs from the exclusion pass, in two classes: a
        // positional edge graze (the check ran; a note) and characters whose
        // position could not be measured (the check did not fully run).
        // They fold below FAIL and above the unreadable-page WARN; an
        // unmeasured page outranks every graze (its message names the first
        // such page; the grazed pages join the references), else the graze
        // sentence is composed ONCE over the grazed pages.
        var grazePages: [Int] = []
        var unmeasuredPages: [Int] = []
        var firstUnmeasuredMessage: String?
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
                if outcome.grazed {
                    grazePages.append(i)
                } else {
                    unmeasuredPages.append(i)
                    if firstUnmeasuredMessage == nil { firstUnmeasuredMessage = msg }
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
        // exclusion message is the more actionable of the two). An
        // unmeasured position (the check did not fully run) outranks a graze
        // (a positional note; the check ran); the grazed pages ride along
        // as references.
        if let msg = firstUnmeasuredMessage {
            return (.warn(msg), (unmeasuredPages + grazePages).sorted(), true)
        }
        if !grazePages.isEmpty {
            return (SandwichVerification.grazeWarning(pages: grazePages), grazePages, false)
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

func pageCountPhrase(_ count: Int) -> String {
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
