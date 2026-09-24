import Foundation
import PDFKit
import Vision
import ImageIO
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

// Layer 2 (OCR on Output), the sweep half: the per-page OCR pass on the dedicated
// Vision queue, the bounded task group over the document's pages, the per-page bucket
// and the cross-page fold into the layer's verdict. Moved whole from
// VerificationEngine.swift; no line inside a moved body changes.

extension VerificationEngine {

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

    /// Maps one page's classifier finding to its fold bucket. Static seam so  // LegalPhrases:safe (identifier)
    /// the mapping matrix is unit-testable without Vision
    /// (`Layer2FoldOrderTests`); `classifyPageImages` is its only caller.
    static func pageBucket(
        for finding: PageOCRFinding, effectiveMode: PipelineMode  // LegalPhrases:safe (identifier)
    ) -> PageOCRBucket {
        switch finding {  // LegalPhrases:safe (identifier)
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
    func runLayer2OCR(
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
}
