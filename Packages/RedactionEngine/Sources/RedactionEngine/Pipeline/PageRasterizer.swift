import CoreGraphics
import PDFKit
#if canImport(UIKit)
import UIKit
#endif
import os

// ENGINE §2.4, §2.7, §7.1 — Page rasterization, render timeout,
// and per-page processing loop.

/// KI-5: `os_proc_available_memory()` does not accurately reflect CGImage
/// allocations due to mmap/copy-on-write backing, so it cannot drive DPI
/// budgeting. The dpiCap (lowered to 150 on
/// UIApplication.didReceiveMemoryWarningNotification by the app-layer
/// PipelineCoordinator) is the effective memory guard. A large sentinel is
/// passed into `selectDPI` so the ceiling is imposed via `userMaxDPI`.
///
/// `rasterize` runs `validatePage` as a pre-flight
/// front gate — it rejects out-of-range dimensions / non-default `/UserUnit`
/// pages and, on real hardware, pages whose raster would exceed half
/// of available memory. The 10,000-pt `pageDimensionLimit` pre-flight inside
/// `renderPageWithTimeout` sits behind it as defense-in-depth for any
/// path that reaches the synchronous draw without the front gate.
private let dpiBudgetSentinel: Int = Int.max / 4

/// Default DPI ceiling used when rasterize is called without an explicit cap.
public let defaultDPICap: Int = 300

/// L-19: Guard against CGContextDrawPDFPage running for seconds on
/// pathologically large pages — the synchronous C call has no cancellation
/// points, so the existing 30s timeout cannot interrupt it.
private let pageDimensionLimit: CGFloat = 10_000

/// PERF-8: os_signpost emission around the synchronous `drawPDFPage` call so
/// the wall-clock can be sampled in Instruments without re-instrumenting
/// every release. The signpost intervals are cheap (`OSSignposter`
/// emits only when a tool is attached or the category is enabled) and let
/// us defer the chunking decision until we have field data on real devices.
///
/// Locked decision (plan §5 PERF-8): `drawPDFPage` is NOT chunked in V1.
/// Chunking the synchronous draw risks aliasing seams between bands. On the
/// `RawPDFBuilder`-generated test fixtures and the iPhone 17 simulator the
/// single-call render stays well under the 200 ms threshold that would
/// motivate chunking. Real-device validation is tracked as a V1.1 follow-up
/// in `specs/TESTING_AND_CI.md`. The 256-row cancellation bands inside
/// `applyRedactionFills` / `verifyFill` cover the long-running CPU loops we
/// do own.
private let pageRasterizerSignposter = OSSignposter(
    subsystem: "com.resecta.engine", category: "PageRasterizer"
)

/// PD-5 / RC-5: runtime per-page fallbacks are logged (page index + generic
/// reason only — never document content, ARCH §12.2) and recorded on the
/// RasterizeResult so the verification report can say why a page rasterized.
private let pageRasterizerLogger = Logger(
    subsystem: "com.resecta.engine", category: "PageRasterizer"
)

/// Wrap a `CGPDFPage` so it can be captured by the `sending`-typed
/// `addTask` closure of the render timeout group under Swift 6.2 strict
/// concurrency (same rationale as `SendablePDFPage`). The wrapped page is
/// consumed by a single render task; concurrent-read safety of the underlying
/// `CGPDFPage` across DIFFERENT tasks is validated by `PDFKitConcurrencyStressTests`.
private struct SendableCGPDFPage: @unchecked Sendable {
    let page: CGPDFPage
    init(_ page: CGPDFPage) { self.page = page }
}

/// Processor for single-page rasterization and pixel destruction.
/// nonisolated by SPM package default. Entry point is `@concurrent`.
/// See ARCH §3.2 for the two-layer concurrency pattern.
///
/// **Why a class.** Owns a per-pipeline-run `BitmapContextPool`
/// (PERF-5). The pool is reference-typed and its eviction order is
/// mutated on every page, so the rasterizer carries it as private
/// state. The public surface is unchanged: callers still construct
/// with `PageRasterizer()` and call the same `@concurrent` methods.
/// The pipeline coordinator creates one rasterizer per run; pages are
/// rasterized with bounded parallelism (PERF-2), so several `rasterize`
/// calls share one instance concurrently.
///
/// `@unchecked Sendable`: the only shared mutable state is the
/// `BitmapContextPool`, which guards its `entries` internally and is
/// therefore safe under concurrent `rasterize` calls. The pre-extraction
/// discipline keeps every other concurrent access off the shared PDFKit object
/// graph by pre-extracting page geometry / `cgPage` serially into
/// `PDFPageData`; the concurrent render path is then CG-only.
public final class PageRasterizer: @unchecked Sendable {

    /// Bitmap context pool. Released when the rasterizer goes out of
    /// scope at the end of the pipeline run. See plan §5 PERF-5.
    private let bitmapPool = BitmapContextPool()

    public init() {}

    /// Drop every entry in the per-rasterizer bitmap pool. Called from
    /// `PipelineCoordinator.memoryWarningTask` after iOS posts a memory
    /// warning, so the up to ~135 MB of held bitmap buffers (4 entries ×
    /// a ~33.7 MB US-Letter raster: 2550×3300 px × 4 B at 300 DPI) are
    /// released immediately rather than waiting for the rasterizer to drop at
    /// run end. Idempotent and thread-safe against in-flight
    /// `rasterize(...)` calls (pool guards `entries` internally).
    /// Audit `03-security-perf-audit.md §5.2.a`.
    public func flushBitmapPool() {
        bitmapPool.flush()
    }

    /// Process a single page: rasterize → fill → verify → return.
    /// For Searchable Redaction pages, text extraction and character filtering
    /// happen before rasterization (Phase 7).
    /// See ENGINE §7.1 for the canonical per-page processing loop.
    ///
    /// `dpiCap` is the MainActor-owned ceiling maintained by the pipeline
    /// coordinator (lowered on memory-warning notifications per KI-5).
    @concurrent
    public func rasterize(_ page: PDFPageData, dpiCap: Int = defaultDPICap) async throws -> RasterizeResult {
        try Task.checkCancellation()

        // Pre-flight page validation is the front gate.
        // Rejects pages whose dimensions exceed the supported range (≤5,000 pt
        // per side / no non-default /UserUnit) and, on real hardware, whose
        // raster would exceed half of available memory; the memory clause
        // defers to the runtime DPI cap + selectDPI when
        // os_proc_available_memory() is unreadable. The 10,000-pt dimension
        // guard inside renderPageWithTimeout remains a defense-in-depth
        // backstop behind this. effectiveDPI mirrors the cap applied below so
        // the estimate matches what will actually be rendered.
        guard validatePage(page.page, effectiveDPI: min(page.targetDPI, dpiCap)) else {
            throw PipelineError.redactionError(.insufficientMemory(pageIndex: page.pageIndex))
        }

        // PERF-1 test seam — records call telemetry and optionally injects a
        // `fillVerificationFailed` for the page index on the next attempt.
        // Activation is task-local (see `PageRasterizerTestSeam.withActivated`)
        // so concurrent tests do not race on shared state. Release builds
        // compile to a no-op (`recordCallAndShouldFail` always returns false),
        // so the seam adds nothing in shipping binaries.
        if PageRasterizerTestSeam.recordCallAndShouldFail(
            pageIndex: page.pageIndex, dpiCap: dpiCap
        ) {
            throw PipelineError.redactionError(
                .fillVerificationFailed(pageIndex: page.pageIndex)
            )
        }

        // ENGINE §5A: Searchable Redaction requires a text layer.
        // Callers should set .secureRasterization for textless pages.
        // Graceful fallback exists, but this catches logic bugs in debug builds.
        // Read the pre-extracted `hasText` (computed serially at build
        // time) instead of a live `page.page.string` scan in the concurrent path.
        assert(
            page.pipelineMode == .secureRasterization || page.hasText,
            "searchableRedaction mode set for page \(page.pageIndex) with no text layer"
        )

        // 1. Select DPI. The user's targetDPI is further capped by dpiCap
        // (lowered under memory pressure); size-based tier selection still
        // runs inside selectDPI but over a sentinel budget (see KI-5 note
        // above).
        // Pre-extracted geometry (serial), not a live `page.page` read.
        let rawBounds = page.cropBoxBounds
        let effectiveSize = effectiveBounds(rawBounds, rotation: page.rotation).size
        let effectiveMaxDPI = min(page.targetDPI, dpiCap)
        guard let dpi = selectDPI(
            availableMemory: dpiBudgetSentinel, userMaxDPI: effectiveMaxDPI,
            pageWidth: effectiveSize.width, pageHeight: effectiveSize.height
        ) else {
            throw PipelineError.redactionError(.insufficientMemory(pageIndex: page.pageIndex))
        }

        // 2. Text extraction for Searchable Redaction (ENGINE §5B)
        // Extract character positions BEFORE rasterization to capture from source PDF.
        // For Secure Rasterization pages, skip entirely.
        var textLayerEntries: [CharacterInfo]? = nil
        var pageDigest: PageFilterDigest? = nil
        // J-12: the text-layer line assembly receives the page's redaction
        // rects (PDF points) so a bridge never crosses one (ENGINE §5C.1).
        var redactionRectsForTextLayer: [CGRect] = []
        // PD-5: effective per-page fallback reason. Starts as the pre-flight
        // reason recorded at build time (non-nil only for fallback pages of a
        // Searchable-mode run); the runtime fallback paths below overwrite it.
        var fallbackReason = page.fallbackReason

        if page.pipelineMode == .searchableRedaction {
            let extractor = TextLayerExtractor()
            do {
                let characters = try await extractor.extractCharacters(
                    from: page.page, hasHiddenOCG: page.hasHiddenOCG
                )

                // Check for fallback triggers (ENGINE §5A)
                // >1% U+FFFD check on extracted characters (tightened from 5% —
                // at 5%, up to 95% of CJK text could survive in the text layer)
                let replacementCount = characters.filter {
                    $0.character.unicodeScalars.contains("\u{FFFD}")
                }.count
                let shouldFallback = characters.count > 0
                    && Double(replacementCount) / Double(characters.count) > 0.01

                if !shouldFallback && !characters.isEmpty {
                    // Convert redaction regions to OUTPUT-page coordinates.
                    // The region basis is the zero-origin output
                    // page (`effectiveSize`), matching the cropBox-LOCAL
                    // character bounds `extractCharacters` now produces — the
                    // canonical coordinate contract. `effectiveSize` derives from
                    // the pre-extracted `cropBoxBounds`, so this keeps
                    // BOTH invariants: a zero-origin region basis AND zero live
                    // `page.page` reads in the concurrent path (this
                    // statement overwrites the earlier `cropBoxBounds` value, while
                    // the :119 geometry read survives). For an un-rotated page
                    // `effectiveSize` equals the cropBox size; the origin is zero.
                    // This one `pageBounds` feeds all FOUR synchronized consumers
                    // (ADV-2 A2-5): the rect filter, the polygon shapes,
                    // `redactionRectsForTextLayer` (the §5C.1 bridge check), and
                    // `filterResult.toDigest(redactionRects:)`. Never give the
                    // digest an independent conversion.
                    let pageBounds = CGRect(origin: .zero, size: effectiveSize)
                    let redactionRectsInPoints = page.regions.map {
                        normalizedToPDFPageCoordinates($0.normalizedRect, pageRect: pageBounds)
                    }

                    // DRAW-1: build polygon-aware shapes alongside the rect-
                    // only path. Pure rectangle pages still consume the
                    // pre-filter against `expandedBounds` only; polygon
                    // pages add the polygon test for the final overlap
                    // check. The expanded polygon is constructed by
                    // applying the safety margin to the bounding box and
                    // converting each vertex into the same coordinate
                    // system used for the rect path.
                    let hasAnyPolygon = page.regions.contains {
                        ($0.vertices?.count ?? 0) >= 3
                    }

                    let filterResult: FilterResult
                    if hasAnyPolygon {
                        let shapes: [RegionShape] = zip(page.regions, redactionRectsInPoints)
                            .map { region, rect in
                                let expanded = rect.insetBy(
                                    dx: -safetyMarginPoints, dy: -safetyMarginPoints
                                )
                                guard let normalized = region.vertices,
                                      normalized.count >= 3 else {
                                    return RegionShape(
                                        expandedBounds: expanded,
                                        polygonVertices: nil,
                                        bounds: rect
                                    )
                                }
                                let inPoints = normalized.map { v in
                                    normalizedToPDFPageCoordinates(
                                        CGRect(x: v.x, y: v.y, width: 0, height: 0),
                                        pageRect: pageBounds
                                    ).origin
                                }
                                return RegionShape(
                                    expandedBounds: expanded,
                                    polygonVertices: inPoints,
                                    bounds: rect
                                )
                            }
                        filterResult = try await filterCharacters(
                            characters: characters,
                            regionShapes: shapes
                        )
                    } else {
                        // Filter characters against redaction regions (§5B.2)
                        filterResult = try await filterCharacters(
                            characters: characters,
                            redactionRects: redactionRectsInPoints
                        )
                    }

                    textLayerEntries = filterResult.surviving
                    redactionRectsForTextLayer = redactionRectsInPoints
                    pageDigest = filterResult.toDigest(
                        pageIndex: page.pageIndex,
                        redactionRects: redactionRectsInPoints,
                        safetyMargin: safetyMarginPoints
                    )
                } else {
                    // shouldFallback or empty: textLayerEntries remains nil,
                    // page processed as Secure Rasterization (ENGINE §5A
                    // TL-7-1). PD-5: record which runtime condition it was.
                    fallbackReason = shouldFallback
                        ? .cjkEncodingFailure : .noExtractableText
                    pageRasterizerLogger.log(
                        "page \(page.pageIndex) fell back to secure rasterization at runtime (\(shouldFallback ? "replacement-character ratio" : "empty extraction", privacy: .public))"
                    )
                }
            } catch { // LegalPhrases:safe (Swift keyword)
                // Extraction threw (e.g., OCG defense) — per-page fallback
                // to Secure Rasterization. textLayerEntries remains nil (TL-7-1).
                // PD-5 / RC-5: record + log the runtime reason (reason text
                // only — no document content, ARCH §12.2).
                fallbackReason = .extractionFailed
                pageRasterizerLogger.log(
                    "page \(page.pageIndex) fell back to secure rasterization at runtime (text extraction threw)"
                )
            }
        }

        // 3. Render page with timeout (ENGINE §2.7)
        // CG-only concurrent render path — draw the pre-extracted
        // `cgPage` with the pre-extracted `cropBoxBounds`/`rotation`; the shared
        // `PDFPage` is never touched here. (`renderPageWithTimeout(PDFPage,…)`
        // is retained as a test seam only.)
        guard let cgPage = page.cgPage else {
            throw PipelineError.redactionError(.bitmapCreationFailed(pageIndex: page.pageIndex))
        }
        let renderedImage = try await renderCGPageWithTimeout(
            cgPage, bounds: page.cropBoxBounds, rotation: page.rotation,
            pageIndex: page.pageIndex, dpi: CGFloat(dpi)
        )

        // ENGINE §7.1: autoreleasepool wraps the synchronous bitmap work
        // (context creation, fill, verify, image extraction) to release ObjC
        // objects between pages. The async portions above cannot be wrapped.
        //
        // PERF-5: bitmap context comes from the per-rasterizer pool. SEC-5:
        // after `makeImage()` returns, the buffer is zeroized AND the
        // context is checked back into the pool (which zeroizes again
        // unconditionally). Both calls are inside this autoreleasepool so
        // the pool entry is wiped before its CGImage retains anything.
        return try autoreleasepool {
            // 4. Check out a mutable context from the pool, draw rendered image
            let width = renderedImage.width
            let height = renderedImage.height
            guard let ctx = self.bitmapPool.checkOut(width: width, height: height) else {
                throw PipelineError.redactionError(.bitmapCreationFailed(pageIndex: page.pageIndex))
            }

            // After `makeImage()` returns, the buffer holds the redacted
            // pixels — zeroize before the context returns to the pool
            // (SEC-5). `defer` covers every exit path including thrown
            // errors so the pool invariant holds even on verify failure.
            defer {
                PixelOperations.zeroizeBitmapBuffer(ctx)
                self.bitmapPool.checkIn(ctx)
            }

            ctx.draw(renderedImage, in: CGRect(x: 0, y: 0, width: width, height: height))

            // 5. Apply fills — bitmap dimensions only, no PDF geometry (ENGINE §3.1)
            // PERF-8: 256-row band cancellation checks happen inside.
            try applyRedactionFills(
                context: ctx, regions: page.regions, fillColor: page.fillColor
            )

            // 6. Verify fills (ENGINE §3.4). PERF-8: 256-row band cancellation
            // checks happen inside; a thrown CancellationError propagates here.
            // DRAW-1: regions with `vertices != nil` route through the
            // polygon-mask scanline verify (only mask-set pixels checked).
            for region in page.regions {
                let verifyPassed: Bool
                if let vertices = region.vertices, vertices.count >= 3 {
                    let pixelVerts = vertices.map { v in
                        normalizedVertexToPixels(
                            v, bitmapWidth: width, bitmapHeight: height
                        )
                    }
                    verifyPassed = try verifyPolygonFill(
                        context: ctx,
                        pixelVertices: pixelVerts,
                        expectedColor: page.fillColor.expectedPixel
                    )
                } else {
                    let pixelRect = normalizedToFillPixels(
                        region.normalizedRect, bitmapWidth: width, bitmapHeight: height
                    )
                    // PD-4-1: Clamp to bitmap bounds
                    let clamped = pixelRect.intersection(
                        CGRect(x: 0, y: 0, width: width, height: height)
                    )
                    guard !clamped.isEmpty else { continue }
                    verifyPassed = try verifyFill(
                        context: ctx, rect: clamped,
                        expectedColor: page.fillColor.expectedPixel
                    )
                }
                guard verifyPassed else {
                    // ENGINE §3.4a: Fill verification failed — the redaction fill did
                    // not produce the expected pixel values across the entire region.
                    throw PipelineError.redactionError(
                        .fillVerificationFailed(pageIndex: page.pageIndex)
                    )
                }
            }

            // 7. Extract final image
            guard let redactedImage = ctx.makeImage() else {
                throw PipelineError.redactionError(.bitmapCreationFailed(pageIndex: page.pageIndex))
            }

            // Use point dimensions (not pixel) for the PDF media box.
            // The CGImage carries the full pixel resolution; CGPDFContext embeds it
            // at native DPI when drawn into the smaller point-sized rect.
            let output = PageOutput(
                image: redactedImage,
                size: effectiveSize,
                textLayerEntries: textLayerEntries,
                redactionRectsInPoints: redactionRectsForTextLayer
            )
            return RasterizeResult(pageOutput: output, filterDigest: pageDigest,
                                   fallbackReason: fallbackReason)
        }
    }

    // MARK: - Render with Timeout (ENGINE §2.7)

    /// Render a page with a 30-second timeout. drawPDFPage() is synchronous C
    /// with no cancellation points — the timeout races against it.
    @concurrent
    func renderPageWithTimeout(
        _ page: PDFPage, pageIndex: Int, dpi: CGFloat
    ) async throws -> CGImage {
        // L-19: Pre-flight bound-check before entering the render task group.
        // drawPDFPage on a pathologically large page can spin for seconds
        // inside the C call; neither the 30s timeout task nor cancelAll()
        // can interrupt it (the outer task leaks a core + battery + thermal).
        let preflightBounds = page.bounds(for: .cropBox)
        guard preflightBounds.width < pageDimensionLimit,
              preflightBounds.height < pageDimensionLimit else {
            throw PipelineError.redactionError(.pageTooLarge(pageIndex: pageIndex))
        }

        // PDFPage is not Sendable but sequential access is guaranteed (ENGINE §1).
        // Wrap in SendablePDFPage so the `sending`-typed addTask closure can
        // capture it under Swift 6.2's stricter sendability checks (Xcode 26.3
        // CI accepts only @unchecked Sendable captures here; 26.4+ also
        // accepts nonisolated(unsafe) but the wrapper works for both).
        let sendablePage = SendablePDFPage(page)
        let idx = pageIndex
        let targetDPI = dpi
        return try await withThrowingTaskGroup(of: CGImage.self) { group in
            group.addTask {
                try await self.renderPage(sendablePage.page, pageIndex: idx, dpi: targetDPI)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(30))
                throw PipelineError.redactionError(.renderTimeout(pageIndex: idx))
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    /// CG-only render-with-timeout, used by the concurrent `rasterize`.
    /// Mirrors `renderPageWithTimeout(PDFPage,…)` but consumes the pre-extracted
    /// `CGPDFPage` + geometry, so no shared `PDFPage` is touched concurrently.
    /// Concurrent-read safety of `CGPDFPage` across tasks is NOT documented by
    /// Apple — it is validated empirically by `PDFKitConcurrencyStressTests`
    /// (TSan, iOS 26 SDK, 2026-06); revalidate on SDK bumps. The other surviving
    /// concurrent PDFKit surfaces are `extractCharacters` (searchable text) and
    /// the OCG `pageReferencesHiddenOCG` `pageRef` walk — both covered by that
    /// harness (ADV-2 A2-12).
    @concurrent
    func renderCGPageWithTimeout(
        _ cgPage: CGPDFPage, bounds: CGRect, rotation: Int,
        pageIndex: Int, dpi: CGFloat
    ) async throws -> CGImage {
        // L-19: Pre-flight bound-check before entering the render task group —
        // drawPDFPage on a pathologically large page spins inside an
        // uninterruptible C call (same defense as the PDFPage overload).
        guard bounds.width < pageDimensionLimit,
              bounds.height < pageDimensionLimit else {
            throw PipelineError.redactionError(.pageTooLarge(pageIndex: pageIndex))
        }

        // Wrap for the `sending`-typed addTask capture (see SendableCGPDFPage).
        let sendableCG = SendableCGPDFPage(cgPage)
        let idx = pageIndex
        let targetDPI = dpi
        let rawBounds = bounds
        let pageRotation = rotation
        return try await withThrowingTaskGroup(of: CGImage.self) { group in
            group.addTask {
                try await self.renderPageFromCGPage(
                    sendableCG.page, bounds: rawBounds, rotation: pageRotation,
                    pageIndex: idx, dpi: targetDPI
                )
            }
            group.addTask {
                try await Task.sleep(for: .seconds(30))
                throw PipelineError.redactionError(.renderTimeout(pageIndex: idx))
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    // MARK: - Core Render (ENGINE §2.4)

    /// Render a PDF page to a CGImage using CGPDFPage (NOT PDFPage.draw()).
    /// Handles cropBox origin, /Rotate, DPI scaling, and anti-aliasing defense.
    /// See ENGINE §2.4 — R5: NEVER use PDFPage.draw(with:to:).
    @concurrent
    public func renderPage(
        _ page: PDFPage, pageIndex: Int,
        box: PDFDisplayBox = .cropBox,
        dpi: CGFloat = 300
    ) async throws -> CGImage {
        try Task.checkCancellation()

        guard let cgPage = page.pageRef else {
            throw PipelineError.redactionError(.bitmapCreationFailed(pageIndex: pageIndex))
        }

        // 1. Get raw cropBox and rotation
        let rawRect = page.bounds(for: box)
        let rotation = page.rotation

        // 2. Compute post-rotation visual dimensions (ENGINE §2.2)
        let effectiveSize: CGSize = (rotation == 90 || rotation == 270)
            ? CGSize(width: rawRect.height, height: rawRect.width)
            : rawRect.size

        // 3. Compute pixel dimensions at target DPI
        let scale = dpi / 72.0
        let pw = Int(ceil(effectiveSize.width * scale))
        let ph = Int(ceil(effectiveSize.height * scale))

        guard let ctx = createBitmapContext(width: pw, height: ph) else {
            throw PipelineError.redactionError(.bitmapCreationFailed(pageIndex: pageIndex))
        }

        // 4. White background (AC-1: UIColor on iOS)
        #if canImport(UIKit)
        ctx.setFillColor(UIColor.white.cgColor)
        #else
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        #endif
        ctx.fill(CGRect(x: 0, y: 0, width: pw, height: ph))

        // 5. Security: disable font smoothing (Bland et al. defense, ENGINE §2.3)
        ctx.setShouldSmoothFonts(false)
        ctx.setShouldSubpixelQuantizeFonts(false)
        ctx.setAllowsFontSubpixelPositioning(false)

        // 6. getDrawingTransform handles cropBox origin, /Rotate, clipping.
        let targetRect = CGRect(x: 0, y: 0, width: effectiveSize.width, height: effectiveSize.height)
        let transform = cgPage.getDrawingTransform(
            box == .cropBox ? .cropBox : .mediaBox,
            rect: targetRect,
            rotate: 0,
            preserveAspectRatio: true
        )

        // 7. DPI scale first, then drawing transform
        ctx.scaleBy(x: scale, y: scale)
        ctx.concatenate(transform)

        // 8. Clip to cropBox
        let cropBox = cgPage.getBoxRect(box == .cropBox ? .cropBox : .mediaBox)
        ctx.addRect(cropBox)
        ctx.clip()

        // 9. Render using CoreGraphics (NOT PDFKit's draw() — R5).
        // PERF-8: wrap the synchronous C call in a signpost interval so
        // Instruments can sample wall-clock without code changes. See the
        // top-of-file note for why chunking is deliberately deferred.
        let signpostID = pageRasterizerSignposter.makeSignpostID()
        let signpostState = pageRasterizerSignposter.beginInterval(
            "drawPDFPage", id: signpostID, "page=\(pageIndex) dpi=\(Int(dpi))"
        )
        ctx.drawPDFPage(cgPage)
        pageRasterizerSignposter.endInterval("drawPDFPage", signpostState)

        guard let image = ctx.makeImage() else {
            throw PipelineError.redactionError(.bitmapCreationFailed(pageIndex: pageIndex))
        }
        return image
    }

    /// The body of `renderPage(PDFPage,…)` rewritten to consume a
    /// pre-extracted `CGPDFPage` + PDFKit-sourced `bounds`/`rotation` directly,
    /// so the concurrent render path never reads the live `PDFPage`. The box is
    /// always `.cropBox` (the production call site). Pixel output is identical
    /// to the PDFPage overload — the same `bounds`/`rotation` feed the
    /// pixel-dimension math and `selectDPI` already consumed them. R5: render
    /// via CoreGraphics (`drawPDFPage`), never the PDFKit page-level draw API.
    @concurrent
    func renderPageFromCGPage(
        _ cgPage: CGPDFPage, bounds: CGRect, rotation: Int,
        pageIndex: Int, dpi: CGFloat
    ) async throws -> CGImage {
        try Task.checkCancellation()

        let rawRect = bounds

        // Compute post-rotation visual dimensions (ENGINE §2.2)
        let effectiveSize: CGSize = (rotation == 90 || rotation == 270)
            ? CGSize(width: rawRect.height, height: rawRect.width)
            : rawRect.size

        // Compute pixel dimensions at target DPI
        let scale = dpi / 72.0
        let pw = Int(ceil(effectiveSize.width * scale))
        let ph = Int(ceil(effectiveSize.height * scale))

        guard let ctx = createBitmapContext(width: pw, height: ph) else {
            throw PipelineError.redactionError(.bitmapCreationFailed(pageIndex: pageIndex))
        }

        // White background (AC-1: UIColor on iOS)
        #if canImport(UIKit)
        ctx.setFillColor(UIColor.white.cgColor)
        #else
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        #endif
        ctx.fill(CGRect(x: 0, y: 0, width: pw, height: ph))

        // Security: disable font smoothing (Bland et al. defense, ENGINE §2.3)
        ctx.setShouldSmoothFonts(false)
        ctx.setShouldSubpixelQuantizeFonts(false)
        ctx.setAllowsFontSubpixelPositioning(false)

        // getDrawingTransform handles cropBox origin, /Rotate, clipping.
        let targetRect = CGRect(x: 0, y: 0, width: effectiveSize.width, height: effectiveSize.height)
        let transform = cgPage.getDrawingTransform(
            .cropBox, rect: targetRect, rotate: 0, preserveAspectRatio: true
        )

        // DPI scale first, then drawing transform
        ctx.scaleBy(x: scale, y: scale)
        ctx.concatenate(transform)

        // Clip to cropBox
        let cropBox = cgPage.getBoxRect(.cropBox)
        ctx.addRect(cropBox)
        ctx.clip()

        // Render using CoreGraphics (NOT PDFKit's draw() — R5).
        let signpostID = pageRasterizerSignposter.makeSignpostID()
        let signpostState = pageRasterizerSignposter.beginInterval(
            "drawPDFPage", id: signpostID, "page=\(pageIndex) dpi=\(Int(dpi))"
        )
        ctx.drawPDFPage(cgPage)
        pageRasterizerSignposter.endInterval("drawPDFPage", signpostState)

        guard let image = ctx.makeImage() else {
            throw PipelineError.redactionError(.bitmapCreationFailed(pageIndex: pageIndex))
        }
        return image
    }
}
