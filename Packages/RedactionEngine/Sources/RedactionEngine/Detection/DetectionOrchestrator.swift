import CoreGraphics
import Foundation
import OSLog
import PDFKit
import Vision

// GAP §3.1 — Detection orchestration wrapper.

// MARK: - PERF-4 — Embedded text source (used to bypass Vision OCR)

/// Sendable carrier for a page's embedded text layer, used to bypass Vision
/// OCR on pages where the embedded text is authoritative (PERF-4 fast path).
///
/// `PipelineCoordinator` builds an instance from `PDFPage` (which is not
/// Sendable) via the static `make(from:cropBox:)` factory, then passes the
/// value into `DetectionOrchestrator.detectPage(...)`. Coordinates are
/// **normalized, bottom-left origin (0–1)** to match Vision's OCR output and
/// the downstream coordinate model used by `boundingRect(for:in:)`. The rects
/// are in the zero-origin, rotation-applied DISPLAYED output-page frame
/// (`effectiveSize` basis, W/H swapped for /Rotate 90/270) — the same frame
/// `TextLayerExtractor.extractCharacters` produces and the burn-in consumes
/// (the canonical coordinate contract).
public struct EmbeddedTextSource: Sendable {
    /// Full extracted text for the page (newline-separated lines).
    public let text: String
    /// Per-word `(NSRange, normalized CGRect)` entries, in document order.
    /// Drives `boundingRect(for:in:)` exactly as Vision word bounds would.
    public let wordBounds: [WordBound]
    /// Per-line records used by `AddressSpatialAssembler`.
    public let lines: [OCREngine.TextLine]
    /// Selectable-text coverage as a fraction of cropBox area in [0, 1].
    /// Used by the coordinator gate (locked > 0.95) and surfaced for tests.
    public let coverage: Double

    public init(
        text: String,
        wordBounds: [WordBound],
        lines: [OCREngine.TextLine],
        coverage: Double
    ) {
        self.text = text
        self.wordBounds = wordBounds
        self.lines = lines
        self.coverage = coverage
    }

    /// `(NSRange, CGRect)` is not directly Sendable in Swift 6.2 strict mode,
    /// so we wrap the pair in a Sendable value type.
    public struct WordBound: Sendable {
        public let range: NSRange
        public let normalizedRect: CGRect

        public init(range: NSRange, normalizedRect: CGRect) {
            self.range = range
            self.normalizedRect = normalizedRect
        }
    }

    /// Build an `EmbeddedTextSource` from a PDF page. Iterates words via
    /// `NSString.enumerateSubstrings(options: .byWords)` and pulls each
    /// word's PDF-space bounding box via `PDFSelection.bounds(for:)`.
    ///
    /// Coverage is computed as the sum of word-box areas divided by cropBox
    /// area. On a typical text page words do not overlap; the small amount
    /// of letter-spacing whitespace is correctly excluded because the gate
    /// uses a strict `> 0.95` threshold. Returns `nil` if the page has no
    /// extractable text or has a zero-size cropBox.
    public static func make(from page: PDFPage) -> EmbeddedTextSource? {
        let cropBox = page.bounds(for: .cropBox)
        return make(from: page, cropBox: cropBox)
    }

    /// Variant that takes a pre-computed cropBox (avoids redundant PDFKit
    /// trips in callers that already have it).
    public static func make(
        from page: PDFPage, cropBox: CGRect
    ) -> EmbeddedTextSource? {
        let pageArea = cropBox.width * cropBox.height
        guard pageArea > 0,
              let text = page.string,
              !text.isEmpty else {
            return nil
        }

        // Canonical coordinate contract: /Rotate is a DISPLAY attribute and
        // `sel.bounds(for:)` is invariant under it, so word/line rects must be
        // mapped into the displayed output-page frame the burn-in consumes —
        // the same displayed-frame migration applied to `extractCharacters`.
        // `effectiveSize` is the rotated output-page size (W/H swapped for
        // 90/270); identity for 0/180.
        let normalizedRotation = ((page.rotation % 360) + 360) % 360
        let effectiveSize = (normalizedRotation == 90 || normalizedRotation == 270)
            ? CGSize(width: cropBox.height, height: cropBox.width)
            : cropBox.size

        let nsText = text as NSString
        let totalCodeUnits = page.numberOfCharacters

        var wordBounds: [WordBound] = []
        var lineBuckets: [(yMid: CGFloat, words: [(rect: CGRect, text: String)])] = []
        var areaSum: CGFloat = 0

        nsText.enumerateSubstrings(
            in: NSRange(location: 0, length: nsText.length),
            options: .byWords
        ) { _, wordRange, _, _ in
            // Defensive: PDFKit ranges are UTF-16; clip to numberOfCharacters.
            let clippedLength = min(
                wordRange.length,
                max(0, totalCodeUnits - wordRange.location)
            )
            guard clippedLength > 0,
                  wordRange.location >= 0,
                  wordRange.location < totalCodeUnits else { return }
            let safeRange = NSRange(
                location: wordRange.location, length: clippedLength
            )
            guard let sel = page.selection(for: safeRange) else { return }
            let bounds = sel.bounds(for: page)
            guard bounds.width > 0, bounds.height > 0 else { return }

            areaSum += bounds.width * bounds.height
            // CND-02: land the word rect in the zero-origin displayed frame the
            // burn-in consumes (identity for an unrotated zero-origin page).
            let normalized = Self.displayedNormalizedRect(
                bounds, cropBox: cropBox,
                effectiveSize: effectiveSize, rotation: normalizedRotation
            )
            wordBounds.append(WordBound(
                range: safeRange, normalizedRect: normalized
            ))

            let yMid = bounds.midY
            let wordText = nsText.substring(with: safeRange)
            let lineTolerance = max(bounds.height * 0.5, 2.0)
            if let idx = lineBuckets.firstIndex(where: {
                abs($0.yMid - yMid) <= lineTolerance
            }) {
                lineBuckets[idx].words.append((bounds, wordText))
            } else {
                lineBuckets.append((yMid, [(bounds, wordText)]))
            }
        }

        let coverage = Double(areaSum / pageArea)

        // Build OCREngine.TextLine entries from line buckets. Each line is
        // the union of its words' rects (in normalized coords) plus the
        // concatenated text. Used by AddressSpatialAssembler.
        let lines: [OCREngine.TextLine] = lineBuckets
            .sorted { $0.yMid > $1.yMid }  // top-to-bottom in PDF (bottom-left origin)
            .map { bucket in
                let sortedWords = bucket.words.sorted { $0.rect.minX < $1.rect.minX }
                let lineText = sortedWords.map(\.text).joined(separator: " ")
                let unionRect = sortedWords
                    .map(\.rect)
                    .reduce(CGRect.null) { $0.union($1) }
                // CND-02: same displayed-space transform as the word path; the
                // line union feeds AddressSpatialAssembler via the same consumer.
                let normalized = unionRect == .null ? .zero
                    : Self.displayedNormalizedRect(
                        unionRect, cropBox: cropBox,
                        effectiveSize: effectiveSize, rotation: normalizedRotation
                    )
                return OCREngine.TextLine(
                    text: lineText,
                    normalizedRect: normalized,
                    confidence: 1.0
                )
            }

        return EmbeddedTextSource(
            text: text,
            wordBounds: wordBounds,
            lines: lines,
            coverage: coverage
        )
    }

    /// Land a source-absolute `sel.bounds(for:)` rect in the zero-origin,
    /// rotation-applied DISPLAYED output-page frame and normalize to 0–1 by
    /// `effectiveSize` (the canonical coordinate contract). Mirrors the per-glyph transform in
    /// `TextLayerExtractor.extractCharacters`: localize (subtract the cropBox
    /// origin) → rotate into displayed space (`T_rot`, reusing
    /// the canonical four-case map) → normalize by the rotated output size. For
    /// an unrotated zero-origin page the result is identical to the prior
    /// origin-subtract-and-normalize. The `effectiveSize` dims are non-zero (the
    /// caller's `pageArea > 0` guard), so the denominators are non-zero.
    private static func displayedNormalizedRect(
        _ sourceRect: CGRect,
        cropBox: CGRect,
        effectiveSize: CGSize,
        rotation: Int
    ) -> CGRect {
        let local = sourceRect.offsetBy(dx: -cropBox.minX, dy: -cropBox.minY)
        let displayed = TextLayerExtractor.rotateRectIntoOutputSpace(
            local, sourceCropSize: cropBox.size, rotation: rotation
        )
        return CGRect(
            x: displayed.minX / effectiveSize.width,
            y: displayed.minY / effectiveSize.height,
            width: displayed.width / effectiveSize.width,
            height: displayed.height / effectiveSize.height
        )
    }
}


/// Orchestrates the full detection pipeline for a single page:
/// render → OCR → doctype classify → PII detection (gated) → spatial
/// address assembly → calibrated scoring → face detection → merge.
///
/// Phase 3: primary entry point is `detectPage(...)` which returns a
/// `PageDetectionResult`. The older `detect(pageImage:pageIndex:)` remains
/// as a thin compatibility shim.
public struct DetectionOrchestrator: Sendable {
    private let piiDetector: PIIDetector
    private let classifier = DocumentTypeClassifier()
    private let calibratedScorer = CalibratedScorer()
    // B03 — C1 augment context scorer, decoded once at init. Whole-scorer
    // identity on any load problem; the shipped placeholder is all-w=0, so it
    // contributes 0 at the posterior seam (the w=0 byte-identity control).
    private let contextScorer = ContextScorerWeights.loadFromEngineBundle()
    private let addressAssembler = AddressSpatialAssembler()
    // DRAW-3 — Heuristic signature detector. Triage-only; never auto-applied
    // (enforced at the state layer via `RedactionState.applyDetectionResults`
    // splitting `.signatureCandidate` results into `pendingTriage`).
    private let signatureDetector = SignatureHeuristicDetector()
    private let recognitionLevel: VNRequestTextRecognitionLevel

    // Package H — defense-in-depth pixel caps for `runOCR`. Mirrors the
    // search-OCR path at `DocumentSearcher.swift:38-44`. Per-axis cap blocks
    // axis-anomalous geometries (e.g., 10000×1); total-pixel cap blocks
    // near-axis-cap pages whose 4-byte RGBA buffer would still trip jetsam.
    fileprivate static let maxOCRPixelDimension = 10_000
    fileprivate static let maxOCRPixelCount = 36_000_000

    /// ST-83 — shared pixel-cap predicate: the single condition `runOCR`
    /// skips Vision on, and the condition `detectPage` stamps
    /// `.pixelCapExceeded` provenance for. Internal so gate tests can
    /// exercise it without rebuilding the whole `detectPage` flow.
    internal static func exceedsOCRPixelCap(width: Int, height: Int) -> Bool {
        width > maxOCRPixelDimension
            || height > maxOCRPixelDimension
            || width &* height > maxOCRPixelCount
    }

    /// Absorbing-state floor on the per-category
    /// prior mean (deliberate, 2026-06-10). Chosen so the weakest
    /// category's raw max (account, 0.75), composed with the worst-case
    /// floored prior, still clears every preset threshold:
    /// posterior(0.75, 0.35) ≈ 0.618 > 0.60 balanced. Public so tests
    /// and the Settings reset affordance can reference the shipped value.
    public static let absorbingStateFloor = 0.35

    /// SEC-7 — non-nil whenever this orchestrator was built via
    /// `init(recognitionLevel:diagnostics:)` (SEC-7 entry point through
    /// `PIIDetector.loadWithDiagnostics(...)`). The legacy default init
    /// path produces no diagnostics value (existing callers, all tests).
    public let gazetteerDiagnostics: GazetteerLoadDiagnostics?

    // MARK: - PERF-4 OCR invocation counter

    /// Process-global counter incremented every time `runOCR` is invoked on
    /// a page. Used by `OCRSkipFastPathTests` to assert that the PERF-4 fast
    /// path actually bypassed Vision. Mutated under a serial lock; safe to
    /// read from any actor. Test-only helpers live in
    /// `OCRInvocationCounter` below.
    public enum OCRInvocationCounter {
        private static let lock = NSLock()
        nonisolated(unsafe) private static var _count: Int = 0

        public static var count: Int {
            lock.lock(); defer { lock.unlock() }
            return _count
        }

        public static func reset() {
            lock.lock(); defer { lock.unlock() }
            _count = 0
        }

        fileprivate static func increment() {
            lock.lock(); defer { lock.unlock() }
            _count += 1
        }
    }

    public init(recognitionLevel: VNRequestTextRecognitionLevel = .fast) {
        self.piiDetector = PIIDetector()
        self.recognitionLevel = recognitionLevel
        self.gazetteerDiagnostics = nil
        // Gazetteer / classifier / scorer / address-assembler loaders
        // run as stored-property defaults before this body executes, so the
        // engine is fully constructed by the time we reach this line.
        // Idempotent first-call-wins; subsequent orchestrator constructions
        // are no-ops. Release builds compile to a no-op shim (#if DEBUG in
        // ColdStartTimer.swift).
        ColdStartTimer.shared.markEngineLoaded()
    }

    /// SEC-7 entry point. Constructs the orchestrator from a pre-built
    /// `PIIDetector` + `GazetteerLoadDiagnostics` pair produced by
    /// `PIIDetector.loadWithDiagnostics(bundle:)`. The coordinator uses this
    /// path so the diagnostic value can be threaded into `RedactionState`
    /// for the degraded-mode banner / toast.
    public init(
        recognitionLevel: VNRequestTextRecognitionLevel,
        detector: PIIDetector,
        diagnostics: GazetteerLoadDiagnostics
    ) {
        self.piiDetector = detector
        self.recognitionLevel = recognitionLevel
        self.gazetteerDiagnostics = diagnostics
        ColdStartTimer.shared.markEngineLoaded()
    }

    // MARK: - Phase 3 primary entry point

    /// Detect PII + faces on a single page, threading priors and surface forms
    /// through the scoring layer. Runs Stages 0–6 of the plan per page;
    /// document-level clustering (Stage 5 surfaces) happens in the coordinator
    /// once all pages yield.
    ///
    /// PERF-4 fast path: when `embeddedText` is non-nil, Vision OCR is skipped
    /// and the orchestrator consumes the supplied embedded text layer instead.
    /// Every `DetectionResult` produced on a skipped page carries the matching
    /// `Provenance` so the audit/triage UI can describe the branch decision.
    /// Caller (`PipelineCoordinator`) is responsible for enforcing the locked
    /// gate: selectable-text coverage > 0.95 AND `effectiveMode ==
    /// .searchableRedaction`. Face detection still runs unconditionally because
    /// faces are not derived from the text layer.
    @concurrent
    public func detectPage(
        image: CGImage,
        pageIndex: Int,
        priors: PerCategoryPriors,
        surfaceForms: SurfaceFormDictionary,
        doctypeContext: DoctypeWindow?,
        thresholdVector: PresetThresholdVector? = nil,
        embeddedText: EmbeddedTextSource? = nil,
        ocrSkipReason: DetectionResult.Provenance.OCRSkipReason? = nil
    ) async throws -> PageDetectionResult {
        // PERF-8 / CANCEL-013: entry-level cooperative cancellation.
        try Task.checkCancellation()
        // PERF-4 — Provenance stamp for every detection produced on this page.
        // The provenance is page-level: if OCR is skipped, every PII/face
        // detection on this page is tagged accordingly.
        let provenance: DetectionResult.Provenance
        let text: String
        let characterBounds: [(NSRange, CGRect)]
        let lines: [OCREngine.TextLine]
        if let embedded = embeddedText {
            // Fast path: use the embedded text layer; do NOT invoke Vision OCR.
            text = embedded.text
            characterBounds = embedded.wordBounds.map { ($0.range, $0.normalizedRect) }
            lines = embedded.lines
            provenance = DetectionResult.Provenance(
                ocrSkipped: true,
                ocrSkipReason: ocrSkipReason ?? .coverageHighEnough
            )
        } else {
            // Default path: run Vision OCR.
            (text, characterBounds, lines) = try await runOCR(on: image)
            // ST-83 — when the raster is over the OCR pixel caps, `runOCR`
            // skipped Vision (unchanged behavior) and returned empties;
            // the provenance now records that so the triage UI can tell
            // the user this page's image content was not text-scanned.
            provenance = Self.exceedsOCRPixelCap(
                width: image.width, height: image.height)
                ? DetectionResult.Provenance(
                    ocrSkipped: true, ocrSkipReason: .pixelCapExceeded)
                : .ocrRan
        }

        // Step 2: Doctype classification. If the coordinator supplied a
        // DoctypeWindow (boundary handling), blend with the classifier's output
        // but honor the provided primary.
        let classifierOutput = await classifier.classify(pageText: text)
        let effectiveDoctype: DoctypeClass = doctypeContext?.primary ?? classifierOutput.primary

        // Step 3: PII detection with doctype gating.
        //
        // Document-header threading:
        // For page 1 (index 0) only, extract the first ~512 characters as the
        // document header and pass it to piiDetector.detect so the institution-
        // anchor suppression path can fire on bank/employer name matches in the
        // header. Pages beyond page 1 receive nil — the header-anchor is
        // document-level, not page-level, and we do not have cross-page text
        // available in the per-page orchestration model. 512 chars is chosen
        // as a "first-page first-N characters" prefix; it is sufficient
        // to capture a typical letterhead (name + address block + date).
        //
        // Rationale for nil on pages > 1: DoctypeWindow carries the document-
        // level doctype forward from page 1 to subsequent pages (mirrored here
        // for the header). Piping page-1 text into every page call would
        // require making it available at the call site (currently absent);
        // the minimal faithful threading is page-0-only since that is where
        // institution headers appear in practice.
        let documentHeader: String? = (pageIndex == 0)
            ? String(text.prefix(512))
            : nil

        var rawMatches = await piiDetector.detect(
            in: text, doctype: effectiveDoctype, documentHeader: documentHeader)
        // First PIIDetector.detect(...) returning is the
        // first_detection_ready_ms end-point ("first answer is ready"
        // semantics). Idempotent first-call-wins —
        // every subsequent page is a no-op, so no per-orchestrator flag.
        ColdStartTimer.shared.markFirstDetectionComplete()

        // Step 3a (WS1 item 1.6): Spatial address assembly injected into rawMatches
        // BEFORE resolveOverlaps so assembled candidates participate in overlap
        // dedup, posterior scoring, and W4 gating. (WS1 item 1.6, 2026-06-10)
        // Convert AddressSpatialAssembler.Assembled → PIIDetector.PIIMatch.
        // Overlap resolution uses character ranges; spatial matches carry no
        // character-level range, so we search for the assembled text in the page
        // string. A sentinel range past the end is used when the text is not
        // found (spatial-only match, no corresponding regex hit to dedup against).
        // The spatial rect (unionRect) is stored separately so the Step 4
        // conversion loop can use it in place of character-bound lookup for
        // spatial survivors. Key: match text (spatial addresses are unique by
        // assembled text on a page; duplicate assembled text is extremely rare
        // and gracefully degrades to the first match's rect in that edge case).
        let assembledAddresses = addressAssembler.assemble(lines: lines)
        var spatialRectByText: [String: CGRect] = [:]
        let nsPageText = text as NSString
        let sentinelLocation = nsPageText.length
        for address in assembledAddresses {
            spatialRectByText[address.text] = address.unionRect
            let searchRange = NSRange(location: 0, length: sentinelLocation)
            let foundRange = nsPageText.range(of: address.text, options: [], range: searchRange)
            let matchRange = foundRange.location != NSNotFound
                ? foundRange
                : NSRange(location: sentinelLocation, length: 0)
            rawMatches.append(PIIDetector.PIIMatch(
                text: address.text,
                range: matchRange,
                kind: .address,
                confidence: address.confidence
            ))
        }

        // Step 3b (W10): cross-category overlap resolution. Keeps the
        // highest-confidence match within each overlap group and records
        // the losers by category so CoverageReport can surface the count.
        //
        // D05-F2 — rank overlap winners by the same post-posterior, gate-aware
        // score the W4 gate (Step 4) applies, so a raw-weaker but
        // better-surviving sibling is not discarded before the gate runs. The
        // closure mirrors the per-match category branch + W4 gate below: it
        // floors the posterior via `survivabilityPosterior(...)` (the same
        // `ContextPosteriorFloor` seam S2 added) and reports whether that score
        // clears the preset cutoff. A match with no category / no preset cutoff
        // is reported as surviving at its raw confidence, matching the gate's
        // pass-through for those kinds.
        let resolved = Self.resolveOverlaps(rawMatches) { [self] match in
            guard let category = match.category,
                  let vector = thresholdVector,
                  let cutoff = vector.threshold(for: category) else {
                return SurvivabilityKey(meetsThreshold: true, posterior: match.confidence)
            }
            let finalConfidence = survivabilityPosterior(
                for: match,
                category: category,
                priors: priors,
                effectiveDoctype: effectiveDoctype,
                pageText: text
            )
            return SurvivabilityKey(
                meetsThreshold: finalConfidence >= cutoff,
                posterior: finalConfidence
            )
        }

        // Step 4: Convert PIIMatches → DetectionResults with surface-form
        // short-circuit and calibrated-posterior scoring.
        var detections: [DetectionResult] = []

        for match in resolved.surviving {
            // §A7 surface-form short-circuit: if the user has decided on this
            // text before, honor the decision. Rejected → drop entirely;
            // accepted → bump confidence.
            var bypassScoring = false
            if let decision = surfaceForms.lookup(match.text) {
                if decision == .rejected { continue }
                bypassScoring = true
            }

            // For spatial address survivors, character-bound lookup may fail
            // (sentinel range or text not in character bounds). Fall back to
            // the stored spatial unionRect so the region covers the visual area.
            let rect: CGRect
            if let spatialRect = (match.kind == .address ? spatialRectByText[match.text] : nil) {
                rect = spatialRect
            } else {
                guard let charRect = boundingRect(for: match.range, in: characterBounds) else { continue }
                rect = charRect
            }

            let finalConfidence: Double
            if bypassScoring {
                finalConfidence = max(match.confidence, 0.90)
            } else if let category = match.category {
                // Absorbing-state floor (deliberate,
                // 2026-06-10). Five consecutive rejections push the mixture
                // mean to ≈0.16, where even a max-raw account hit (0.75)
                // posteriors to ≈0.37 < 0.60 balanced and the category can
                // never resurface. Flooring the prior at 0.35 keeps the
                // weakest category's raw max above every preset threshold
                // (0.20 was shown insufficient — see the design's math).
                // Applied at this call site, not inside CalibratedScorer.
                // B03 — the C1 augment threads a learned context log-odds term
                // into posterior() at this same seam. posterior() takes a
                // defaulted `contextLogit`; the shipped placeholder is all-w=0,
                // so learnedContextLogit is 0 and finalConfidence is unchanged
                // (the w=0 byte-identity control). The feature vector is the
                // shared ContextFeatures builder, positional in
                // ContextFeatureContract.featureOrder order.
                let priorMean = max(priors.mean(category), Self.absorbingStateFloor)
                let wire = PresetThresholdVector.wireName(for: category) ?? ""
                let contextLogit = contextScorer.learnedContextLogit(
                    family: wire,
                    features: contextFeatures(
                        match: match,
                        doctype: effectiveDoctype,
                        effectiveDoctype: effectiveDoctype,
                        pageText: text
                    )
                )
                // SRCH-S2 D02-scorer-posterior-F1/F2 — under-redaction posterior
                // floor. The learned context term can drive a keyword-confirmed
                // account/phone below the W4 gate on a length/separator feature
                // alone; re-floor it to the raw bar it already cleared (the
                // preset-invariant conservative cutoff) before W4 consumes
                // finalConfidence. Raw-bar form (DESIGN-DECISIONS DQ2); pure code,
                // no scorer/preset blob change. No-op for non-floored families and
                // for sub-bar raws. See ContextPosteriorFloor.
                let scored = calibratedScorer.posterior(
                    raw: match.confidence,
                    priorMean: priorMean,
                    contextLogit: contextLogit
                )
                finalConfidence = ContextPosteriorFloor.apply(
                    scored,
                    family: wire,
                    raw: match.confidence,
                    conservativeCutoff: ContextPosteriorFloor.conservativeCutoff(forWire: wire)
                )
            } else {
                finalConfidence = match.confidence
            }

            // W4 — gate against the per-category preset threshold using the
            // post-posterior score. Non-calibration categories and missing
            // wire-names pass through. Bypass surface-form hits (already
            // approved by the user).
            if !bypassScoring, let vector = thresholdVector,
               let category = match.category,
               let cutoff = vector.threshold(for: category),
               finalConfidence < cutoff {
                continue
            }

            detections.append(DetectionResult(
                id: UUID(),
                normalizedRect: rect,
                kind: .pii(match.kind),
                confidence: finalConfidence,
                matchedText: match.text,
                recognitionLevel: recognitionLevel == .fast ? .fast : .accurate,
                provenance: provenance
            ))
        }

        // Step 6: Face detection (skip on doctypes where faces are
        // structurally absent, e.g. .financial). Exhaustive switch in
        // `shouldRunFaceDetection` forces a compile-time decision on any
        // future DoctypeClass addition.
        //
        // PERF-4 — Face detection is not derived from the text layer, so it
        // runs unconditionally on the skip path. Re-stamp the face results
        // with the page-level provenance so the audit story stays uniform:
        // "every result on a skipped page carries provenance.ocrSkipped".
        var faceResults: [DetectionResult] = []
        if Self.shouldRunFaceDetection(for: effectiveDoctype) {
            let raw = try await runFaceDetection(on: image)
            if provenance.ocrSkipped {
                faceResults = raw.map { face in
                    DetectionResult(
                        id: face.id,
                        normalizedRect: face.normalizedRect,
                        kind: face.kind,
                        confidence: face.confidence,
                        matchedText: face.matchedText,
                        recognitionLevel: face.recognitionLevel,
                        provenance: provenance
                    )
                }
            } else {
                faceResults = raw
            }
        }
        detections.append(contentsOf: faceResults)

        // Step 6b (DRAW-2): Barcode / QR detection. Like face detection,
        // barcodes are not derived from the text layer, so the pass runs
        // unconditionally on the PERF-4 OCR-skip path. The gate
        // `shouldRunBarcodeDetection(for:)` defaults to `true` for every
        // doctype today; the exhaustive switch is the compile-time forcing
        // point if a future DoctypeClass wants to skip the work.
        // Re-stamp provenance on the OCR-skip path so every detection on a
        // skipped page reports `provenance.ocrSkipped` uniformly.
        //
        // Vision-error tolerance (DRAW-2): barcode detection is an
        // opportunistic surface — a missed barcode is suboptimal but the
        // primary text-PII detection is unaffected. `VNDetectBarcodesRequest`
        // can transiently fail with "Could not create inference context"
        // under simulator load (the same flake `DetectionRasterizeOverlapTests`
        // documents for OCR). The do/error-handling block below intercepts the
        // Vision error locally so a barcode-pass failure does not abort the
        // page's text-PII or face results. Cancellation still propagates so
        // cooperative cancellation works at the pipeline level.
        var barcodeResults: [DetectionResult] = []
        if Self.shouldRunBarcodeDetection(for: effectiveDoctype) {
            do {
                let raw = try await runBarcodeDetection(on: image)
                if provenance.ocrSkipped {
                    barcodeResults = raw.map { barcode in
                        DetectionResult(
                            id: barcode.id,
                            normalizedRect: barcode.normalizedRect,
                            kind: barcode.kind,
                            confidence: barcode.confidence,
                            matchedText: barcode.matchedText,
                            recognitionLevel: barcode.recognitionLevel,
                            provenance: provenance
                        )
                    }
                } else {
                    barcodeResults = raw
                }
            } catch is CancellationError { // LegalPhrases:safe
                throw CancellationError()
            } catch { // LegalPhrases:safe
                // Vision / inference-context error → degrade to empty result
                // set on this page; the rest of the page's detections stand.
                barcodeResults = []
            }
        }
        detections.append(contentsOf: barcodeResults)

        // ENGINE §4.19: Scan barcode payloads for embedded PII. Any PII found
        // shares the barcode's normalizedRect so the redaction covers the physical
        // code region. Payload detections are appended AFTER resolveOverlaps and
        // the W4/posterior loop — they intentionally do NOT participate in overlap
        // resolution (the barcode rect is already authoritative; the payload scan
        // adds informational PII category labels to a region already marked for
        // redaction). Confidence = min(barcode confidence, match confidence).
        // Degradation: if piiDetector.detect times out, the per-detector timeout
        // degrades to empty — the barcode bounding-box detection in detections stands.
        // (WS1 item 1.5, 2026-06-10)
        var barcodePayloadDetections: [DetectionResult] = []
        for barcode in barcodeResults {
            guard let payload = barcode.matchedText, !payload.isEmpty else { continue }
            // PIIDetector.detect(in:doctype:) is @concurrent — already on cooperative pool.
            let payloadMatches = await piiDetector.detect(in: payload, doctype: effectiveDoctype)
            for match in payloadMatches {
                // kind: use match.kind (e.g., .pii(.ssn)) — NOT .pii(.barcode) — so
                // the triage UI shows the PII category, not a generic barcode badge.
                // The original barcode detection is still present in detections.
                barcodePayloadDetections.append(DetectionResult(
                    id: UUID(),
                    normalizedRect: barcode.normalizedRect,
                    kind: .pii(match.kind),
                    confidence: min(barcode.confidence, match.confidence),
                    matchedText: match.text,
                    recognitionLevel: .fast,
                    provenance: provenance
                ))
            }
        }
        detections.append(contentsOf: barcodePayloadDetections)

        // DRAW-3 — Heuristic signature detection. Parallel branch to the
        // face / barcode detectors above. Triage-only: results are tagged
        // `.pii(.signatureCandidate)` and the state-layer's
        // `applyDetectionResults` routes them to `pendingTriage` even when
        // the user has opted into auto-apply. The detector internally skips
        // the Sobel pass when no labeled OCR blocks are present, satisfying
        // the cost-guardrail hard stop in plan §4 DRAW-3.
        let signatureResults = try await signatureDetector.detect(
            in: image,
            ocrBlocks: lines
        )
        if provenance.ocrSkipped {
            // Re-stamp provenance to keep "every result on a skipped page
            // carries provenance.ocrSkipped" — same pattern as face above.
            detections.append(contentsOf: signatureResults.map { result in
                DetectionResult(
                    id: result.id,
                    normalizedRect: result.normalizedRect,
                    kind: result.kind,
                    confidence: result.confidence,
                    matchedText: result.matchedText,
                    recognitionLevel: result.recognitionLevel,
                    provenance: provenance
                )
            })
        } else {
            detections.append(contentsOf: signatureResults)
        }

        // Step 7: Build G5 diagnostic (in-memory only; never logged).
        let diagnostic = classifierOutput.topKeywords.isEmpty
            ? nil
            : ClassificationDiagnostic(from: classifierOutput)

        return PageDetectionResult(
            pageIndex: pageIndex,
            detections: detections,
            doctype: classifierOutput,
            priorsDelta: PerCategoryPriors(),  // priors move on triage, not detection
            classificationDiagnostic: diagnostic,
            overlapSuppressedCountByCategory: resolved.suppressedCountByCategory,
            ocrProvenance: provenance
        )
    }

    // MARK: - L-10: Face-detection doctype gate

    /// Return true iff the doctype may plausibly contain faces. Financial
    /// documents (statements, invoices, receipts) are structurally faceless
    /// so the Vision pass is skipped for privacy transparency and a small
    /// performance win. Court exhibits, medical records, FOIA releases, and
    /// generic (unknown) doctypes may include photos — run face detection.
    ///
    /// Exhaustive switch over `DoctypeClass` with no `default:` — any future
    /// case addition is a compile-time decision point.
    static func shouldRunFaceDetection(for doctype: DoctypeClass) -> Bool {
        switch doctype {
        case .financial: return false
        case .court, .medical, .foia, .generic: return true
        }
    }

    // MARK: - DRAW-2: Barcode-detection doctype gate

    /// Return true iff the doctype may plausibly contain barcodes / QR codes.
    /// Locked decision (plan §4 DRAW-2): on by default for every doctype —
    /// barcodes and QR codes appear across all document classes (medical
    /// labels, court exhibits, FOIA cover sheets, financial check MICRs, and
    /// generic forms). Exhaustive switch over `DoctypeClass` with no
    /// `default:` so any future case addition is a compile-time decision
    /// point parallel to `shouldRunFaceDetection`.
    static func shouldRunBarcodeDetection(for doctype: DoctypeClass) -> Bool {
        switch doctype {
        case .court, .medical, .financial, .foia, .generic: return true
        }
    }

    // MARK: - Deprecated pre-Phase-3 entry point

    /// Legacy entry point kept for existing call sites. Delegates to
    /// `detectPage` with empty priors/surfaceForms and nil doctype context
    /// (every detector runs unconditionally), then unwraps to a flat array.
    @concurrent
    public func detect(
        pageImage: CGImage,
        pageIndex: Int
    ) async throws -> [DetectionResult] {
        let result = try await detectPage(
            image: pageImage,
            pageIndex: pageIndex,
            priors: PerCategoryPriors(),
            surfaceForms: SurfaceFormDictionary(),
            doctypeContext: nil
        )
        return result.detections
    }

    // MARK: - OCR (ENGINE §4.2, GAP §3.1)

    /// Run Vision OCR and return extracted text with per-word bounding boxes
    /// AND the full per-line TextLine array needed by spatial detectors
    /// (AddressSpatialAssembler).
    ///
    /// F2-8: VNImageRequestHandler.perform() is synchronous and blocks the
    /// cooperative thread pool thread (~181ms at .accurate). Acceptable for v1
    /// because the sequential page loop means only one perform() is active at a
    /// time. Post-v1 optimization: wrap in Task.detached to free the coop thread.
    // Internal (rather than private) so `@testable import RedactionEngine`
    // tests can exercise the Package H pixel-cap gate without rebuilding
    // the entire `detectPage` flow.
    internal func runOCR(on image: CGImage) async throws
        -> (String, [(NSRange, CGRect)], [OCREngine.TextLine])
    {
        // Package H — PERF-ocr-engine-cap-only-upstream (`03-security-perf-audit.md
        // §5.3.a`). Defense-in-depth: the only V1.0 caller
        // (`PipelineCoordinator.renderPageForDetection`, `maxDetectionPixels =
        // 4096`) already caps the image, but the engine-side OCR path has no
        // gate of its own. Mirrors `DocumentSearcher.swift:990-992` with the
        // same `maxOCRPixelDimension` / `maxOCRPixelCount` limits — over-cap
        // pages skip Vision and return empty OCR results, equivalent to a page
        // with no detectable text.
        guard !Self.exceedsOCRPixelCap(width: image.width, height: image.height) else {
            detectionLogger.info(
                "runOCR skip: \(image.width, privacy: .public)×\(image.height, privacy: .public) exceeds OCR pixel cap"
            )
            return ("", [], [])
        }

        // PERF-4 — Test-observable counter. Incremented exactly once per
        // Vision OCR invocation so `OCRSkipFastPathTests` can assert that
        // the skip path actually bypassed Vision (and that the non-skip
        // path still invokes it once per page).
        OCRInvocationCounter.increment()

        // OCR quality program: the detection request
        // is built from the shared OCRConfiguration so each program step
        // (revision pin, customWords, minimumTextHeight) lands in exactly
        // one place and is measured by RealDocOCRQualityTests.
        let request = OCRConfiguration
            .detection(recognitionLevel: recognitionLevel)
            .makeRequest()

        let handler = VNImageRequestHandler(cgImage: image)
        try handler.perform([request])

        let observations = request.results ?? []

        // Create the OCR confusable normalizer once
        // before the loop. OCRTextNormalizer is a stateless struct; one instance
        // per runOCR invocation is sufficient and avoids re-constructing it per
        // observation. The downstream piiDetector.detect call then sees
        // normalized text; character ranges still map 1:1 because
        // OCRTextNormalizer is same-length by construction (1:1 substitution,
        // never changes String.count). Letter-context maps are harmless for
        // names — the context-sensitive algorithm handles them correctly.
        let normalizer = OCRTextNormalizer()

        var fullTextParts: [String] = []
        var wordBounds: [(NSRange, CGRect)] = []
        var textLines: [OCREngine.TextLine] = []
        var currentOffset = 0

        for observation in observations {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let rawLineText = candidate.string
            // Normalize confusables before appending
            // so PII detection operates on corrected text.
            let lineText = normalizer.normalize(rawLineText)
            let lineNSString = lineText as NSString

            let lineBounds = extractWordBounds(
                from: candidate,
                observation: observation,
                lineText: lineText,
                lineNSString: lineNSString,
                currentOffset: currentOffset
            )
            wordBounds.append(contentsOf: lineBounds)

            textLines.append(OCREngine.TextLine(
                text: lineText,
                normalizedRect: observation.boundingBox,
                confidence: observation.confidence
            ))

            fullTextParts.append(lineText)
            currentOffset += lineNSString.length + 1
        }

        let fullText = fullTextParts.joined(separator: "\n")
        return (fullText, wordBounds, textLines)
    }

    /// Extract per-word bounding boxes from a VNRecognizedText candidate.
    /// Falls back to the observation's line-level bounding box if word-level
    /// extraction fails for any word.
    private func extractWordBounds(
        from candidate: VNRecognizedText,
        observation: VNRecognizedTextObservation,
        lineText: String,
        lineNSString: NSString,
        currentOffset: Int
    ) -> [(NSRange, CGRect)] {
        var results: [(NSRange, CGRect)] = []

        lineNSString.enumerateSubstrings(
            in: NSRange(location: 0, length: lineNSString.length),
            options: .byWords
        ) { _, wordNSRange, _, _ in
            guard let wordStringRange = Range(wordNSRange, in: lineText) else { return }

            let rect: CGRect
            if let boxObs = try? candidate.boundingBox(for: wordStringRange) {
                rect = Self.quadToRect(boxObs)
            } else {
                rect = observation.boundingBox
            }

            let globalRange = NSRange(
                location: currentOffset + wordNSRange.location,
                length: wordNSRange.length
            )
            results.append((globalRange, rect))
        }

        if results.isEmpty && lineNSString.length > 0 {
            let lineRange = NSRange(location: currentOffset, length: lineNSString.length)
            results.append((lineRange, observation.boundingBox))
        }

        return results
    }

    // MARK: - Bounding Rect Mapping (GAP §3.1)

    /// Map a PIIMatch NSRange to a normalized bounding CGRect by computing the
    /// union of all word bounding boxes that intersect the match range.
    func boundingRect(
        for range: NSRange,
        in characterBounds: [(NSRange, CGRect)]
    ) -> CGRect? {
        var result: CGRect? = nil
        for (wordRange, wordRect) in characterBounds {
            if NSIntersectionRange(wordRange, range).length > 0 {
                if let existing = result {
                    result = existing.union(wordRect)
                } else {
                    result = wordRect
                }
            }
        }
        return result
    }

    // MARK: - Survivability Posterior (D05-F2)

    /// D05-F2 — the floored posterior for a categorized match, used to rank
    /// overlap-resolution winners by the score the W4 gate will apply.
    ///
    /// This replicates the per-match category branch of `detectPage(...)` (the
    /// `priorMean` → `learnedContextLogit` → `posterior` →
    /// `ContextPosteriorFloor.apply` chain, including S2's under-redaction
    /// floor seam) so the resolver's `SurvivabilityKey` scores a match exactly
    /// as the Step 4 gate does. It is intentionally a faithful copy rather than
    /// a shared call site so S2's just-landed gate seam stays byte-identical;
    /// the two MUST stay in sync — any change to the Step 4 category branch
    /// must be mirrored here (and vice-versa).
    private func survivabilityPosterior(
        for match: PIIDetector.PIIMatch,
        category: PIICategory,
        priors: PerCategoryPriors,
        effectiveDoctype: DoctypeClass,
        pageText: String
    ) -> Double {
        let priorMean = max(priors.mean(category), Self.absorbingStateFloor)
        let wire = PresetThresholdVector.wireName(for: category) ?? ""
        let contextLogit = contextScorer.learnedContextLogit(
            family: wire,
            features: contextFeatures(
                match: match,
                doctype: effectiveDoctype,
                effectiveDoctype: effectiveDoctype,
                pageText: pageText
            )
        )
        let scored = calibratedScorer.posterior(
            raw: match.confidence,
            priorMean: priorMean,
            contextLogit: contextLogit
        )
        return ContextPosteriorFloor.apply(
            scored,
            family: wire,
            raw: match.confidence,
            conservativeCutoff: ContextPosteriorFloor.conservativeCutoff(forWire: wire)
        )
    }

    // MARK: - Face Detection (ENGINE §4.8)

    private func runFaceDetection(on image: CGImage) async throws -> [DetectionResult] {
        try await FaceDetector().detect(in: image)
    }

    // MARK: - Barcode Detection (DRAW-2, ENGINE §4.19)

    private func runBarcodeDetection(on image: CGImage) async throws -> [DetectionResult] {
        try await BarcodeDetector().detect(in: image)
    }

    // MARK: - Helpers

    private static func quadToRect(_ obs: VNRectangleObservation) -> CGRect {
        let points = [obs.topLeft, obs.topRight, obs.bottomLeft, obs.bottomRight]
        let xs = points.map(\.x)
        let ys = points.map(\.y)
        let minX = xs.min()!
        let maxX = xs.max()!
        let minY = ys.min()!
        let maxY = ys.max()!
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

private let detectionLogger = Logger(
    subsystem: "app.resecta.engine", category: "DetectionOrchestrator")
