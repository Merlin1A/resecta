import CoreGraphics
import PDFKit
#if canImport(UIKit)
import UIKit
#endif
import os

// Page rasterization, render timeout,
// and per-page processing loop.

// KI-5: `os_proc_available_memory()` does not accurately reflect CGImage
// allocations due to mmap/copy-on-write backing, so it cannot drive DPI
// budgeting. The dpiCap (lowered to 150 on
// UIApplication.didReceiveMemoryWarningNotification by the app-layer
// PipelineCoordinator) is the effective memory guard. The sentinel budget
// (`runTierBudget`) is passed into `selectDPI` by `runQuality`, so the
// ceiling is imposed via `userMaxDPI`.
//
// `rasterize` runs the two pre-flight halves as its front gate —
// `validatePageGeometry` rejects out-of-range dimensions / non-default
// `/UserUnit` pages as `.unsupportedPageGeometry`, then `validatePageMemory`
// rejects, on real hardware, pages whose raster would not fit the
// three-bitmap estimate as `.insufficientMemory`. The 10,000-pt `pageDimensionLimit` pre-flight inside
// `renderCGPageWithTimeout` sits behind it as defense-in-depth for any
// path that reaches the synchronous draw without the front gate.

/// Default DPI ceiling used when rasterize is called without an explicit cap.
public let defaultDPICap: Int = 300

/// Guard against CGContextDrawPDFPage running for seconds on
/// pathologically large pages — the synchronous C call has no cancellation
/// points, so the existing 30s timeout cannot interrupt it.
private let pageDimensionLimit: CGFloat = 10_000

/// os_signpost emission around the synchronous `drawPDFPage` call so
/// the wall-clock can be sampled in Instruments without re-instrumenting
/// every release. The signpost intervals are cheap (`OSSignposter`
/// emits only when a tool is attached or the category is enabled) and let
/// us defer the chunking decision until we have field data on real devices.
///
/// `drawPDFPage` is not chunked in V1. Chunking the synchronous draw risks
/// aliasing seams between bands. On the
/// `RawPDFBuilder`-generated test fixtures and the iPhone 17 simulator the
/// single-call render stays well under the 200 ms threshold that would
/// motivate chunking. Real-device validation remains a tracked follow-up.
/// The 256-row cancellation bands inside
/// `applyRedactionFills` / `verifyFill` cover the long-running CPU loops we
/// do own.
private let pageRasterizerSignposter = OSSignposter(
    subsystem: "com.resecta.engine", category: "PageRasterizer"
)

/// Runtime per-page fallbacks are logged (page index + generic
/// reason only — never document content) and recorded on the
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
///
/// **Why a class.** Owns a per-pipeline-run `BitmapContextPool`.
/// The pool is reference-typed and its eviction order is
/// mutated on every page, so the rasterizer carries it as private
/// state. The public surface is unchanged: callers still construct
/// with `PageRasterizer()` and call the same `@concurrent` methods.
/// The pipeline coordinator creates one rasterizer per run; pages are
/// rasterized with bounded parallelism, so several `rasterize`
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
    /// scope at the end of the pipeline run.
    private let bitmapPool = BitmapContextPool()

    public init() {}

    /// Drop every entry in the per-rasterizer bitmap pool. Called from
    /// `PipelineCoordinator.memoryWarningTask` after iOS posts a memory
    /// warning, so the up to ~135 MB of held bitmap buffers (4 entries ×
    /// a ~33.7 MB US-Letter raster: 2550×3300 px × 4 B at 300 DPI) are
    /// released immediately rather than waiting for the rasterizer to drop at
    /// run end. Idempotent and thread-safe against in-flight
    /// `rasterize(...)` calls (pool guards `entries` internally).
    public func flushBitmapPool() {
        bitmapPool.flush()
    }

    /// Process a single page: rasterize → fill → verify → return.
    /// For Searchable Redaction pages, text extraction and character filtering
    /// happen before rasterization (Phase 7).
    ///
    /// `dpiCap` is the MainActor-owned ceiling maintained by the pipeline
    /// coordinator (lowered on memory-warning notifications per KI-5).
    ///
    /// The work is in stages, in this order: `preflight` (the front gate
    /// and the DPI), `prepareTextLayer` (a Searchable page's text layer,
    /// built before the render), `render`, then the bitmap work in this
    /// function's own autorelease block: the ink test, `paint`, `readBack`,
    /// the image and `buildOutput`. The block and its one `defer` stay here,
    /// so the pooled bitmap is zeroed and returned only after the image is
    /// made.
    @concurrent
    public func rasterize(_ page: PDFPageData, dpiCap: Int = defaultDPICap) async throws -> RasterizeResult {
        let raster = try preflight(page, dpiCap: dpiCap)
        // Written before the render; after it, only the ink test and the
        // plan's widened boxes change it, each through its one drop.
        var textLayer = await prepareTextLayer(page, effectiveSize: raster.effectiveSize)
        let renderedImage = try await render(page, raster: raster)

        // autoreleasepool wraps the synchronous bitmap work
        // (context creation, fill, verify, image extraction) to release ObjC
        // objects between pages. The async portions above cannot be wrapped.
        //
        // Bitmap context comes from the per-rasterizer pool. After
        // `makeImage()` returns, the buffer is zeroized AND the
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
            // pixels — zeroize before the context returns to the pool.
            // `defer` covers every exit path including thrown
            // errors so the pool invariant holds even on verify failure.
            defer {
                PixelOperations.zeroizeBitmapBuffer(ctx)
                self.bitmapPool.checkIn(ctx)
            }

            ctx.draw(renderedImage, in: CGRect(x: 0, y: 0, width: width, height: height))

            // Every box maps onto the bitmap on the content basis, the
            // pixels the page's content spans (the raster rule's S·d / 4608
            // per side), never the bitmap's own count (`normalizedToFillPixels`).
            let content = raster.pixels.content

            // 4b. The hidden-text ink test (`inkTest`).
            try self.inkTest(&textLayer, context: ctx, page: page, pageSize: raster.effectiveSize, content: content)

            // 4c-6. Ink growth, the fills and their readback: the plan's
            // boxes where the page's data carries them (`paintPlan`), else
            // the regions (`paint`, `readBack`).
            var planPaint = PlanPaint()
            if let plan = raster.pixels.plan {
                planPaint = try self.paintPlan(context: ctx, page: page, raster: plan, content: content)
            } else {
                try self.paint(context: ctx, page: page, content: content)
                try self.readBack(context: ctx, page: page, width: width, height: height, content: content)
            }
            // A box the ink check widened: a Searchable page becomes a picture.
            if planPaint.inkWidened { Self.dropTextLayer(&textLayer, reason: .inkEscapesBox, page: page) }

            // 7. Extract final image
            guard let redactedImage = ctx.makeImage() else {
                throw PipelineError.redactionError(.bitmapCreationFailed(pageIndex: page.pageIndex))
            }
            var result = self.buildOutput(textLayer, image: redactedImage, page: page,
                                          pageSize: raster.effectiveSize)
            result.paintedBoxes = planPaint.painted.mapValues {
                RunRecord.PaintedPixels(firstColumn: $0.minX, firstRowFromBottom: $0.minY,
                                        columns: $0.maxX - $0.minX, rows: $0.maxY - $0.minY)
            }
            result.regionsPaintedOutsideThePlan = planPaint.outsidePlan
            result.inkVerdicts = planPaint.inkVerdicts
            return result
        }
    }

    // MARK: - The stages of `rasterize`

    /// The page's output size and DPI as `preflight` settled them.
    struct Raster {
        /// The output page in points: the crop box turned by the page's rotation.
        let effectiveSize: CGSize
        let dpi: Int
        /// The raster's pixels, from the page's data (`pagePixels`).
        let pixels: PagePixels
    }

    /// The front gate, the test seam, the mode check, the DPI and the
    /// page's pixels, which refuse a page whose sides are not its record's.
    /// Throws the page's refusal.
    private func preflight(_ page: PDFPageData, dpiCap: Int) throws -> Raster {
        try Task.checkCancellation()

        // Pre-flight page validation is the front gate, in two halves so
        // each refusal carries its own error case. Geometry first: a side
        // outside 10…5,000 pt or a non-default /UserUnit is
        // `.unsupportedPageGeometry` (import checks 0 < side ≤ 5,000 pt
        // only, so such a page reaches this point). Then memory: on real
        // hardware, a raster that would not fit the three-bitmap estimate
        // is `.insufficientMemory`; the memory clause defers to the runtime
        // DPI cap + selectDPI when os_proc_available_memory() is
        // unreadable. The 10,000-pt dimension guard inside
        // renderCGPageWithTimeout remains a defense-in-depth backstop behind
        // this. effectiveDPI mirrors the cap applied below so the estimate
        // matches what will actually be rendered.
        let effectiveDPI = min(page.targetDPI, dpiCap)
        guard validatePageGeometry(page.page) else {
            throw PipelineError.redactionError(.unsupportedPageGeometry(pageIndex: page.pageIndex))
        }
        guard validatePageMemory(page.page, effectiveDPI: effectiveDPI) else {
            throw PipelineError.redactionError(.insufficientMemory(pageIndex: page.pageIndex))
        }

        // Test seam — records call telemetry and optionally injects a
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

        // Searchable Redaction requires a text layer.
        // Callers should set .secureRasterization for textless pages.
        // Graceful fallback exists, but this catches logic bugs in debug builds.
        // Read the pre-extracted `hasText` (computed serially at build
        // time) instead of a live `page.page.string` scan in the concurrent path.
        assert(
            page.pipelineMode == .secureRasterization || page.hasText,
            "searchableRedaction mode set for page \(page.pageIndex) with no text layer"
        )

        // 1. Select DPI: `runQuality`, the one function the editor's kept
        // plan reads too. The user's targetDPI is further capped by dpiCap
        // (lowered under memory pressure); size-based tier selection still
        // runs inside selectDPI but over a sentinel budget (see KI-5 note
        // above).
        // Pre-extracted geometry (serial), not a live `page.page` read.
        let rawBounds = page.cropBoxBounds
        let effectiveSize = effectiveBounds(rawBounds, rotation: page.rotation).size
        guard let dpi = runQuality(
            chosenDPI: page.targetDPI, dpiCap: dpiCap, cropBox: rawBounds.size, rotation: page.rotation
        ) else {
            // selectDPI returns nil only when no DPI tier fits under the
            // cap — a memory/DPI-budget condition, never geometry (the
            // geometry half above has already passed), so the memory case
            // is the honest class here.
            throw PipelineError.redactionError(.insufficientMemory(pageIndex: page.pageIndex))
        }
        guard let pixels = Self.pagePixels(page, dpi: dpi) else {
            throw PipelineError.redactionError(.bitmapCreationFailed(pageIndex: page.pageIndex))
        }
        // A page whose record's sides are not its own (both read at run
        // entry, the record first): refused by name, before it is rendered
        // or painted.
        guard !pixels.recordDisagrees else {
            throw PipelineError.redactionError(.pageSidesNotAsRecorded(pageIndex: page.pageIndex))
        }
        return Raster(effectiveSize: effectiveSize, dpi: dpi, pixels: pixels)
    }

    /// The text layer, built before the render from the source page. It
    /// never throws: every error from the extraction or the character filter,
    /// cancellation included, is caught here and the page goes on as Secure
    /// Rasterization with the reason recorded.
    ///
    /// Internal, not private, for one characterization pin alone: a
    /// cancelled stage. `rasterize` cannot reach that case, because
    /// `preflight` checks cancellation first.
    func prepareTextLayer(_ page: PDFPageData, effectiveSize: CGSize) async -> TextLayerState {
        // 2. Text extraction for Searchable Redaction
        // Extract character positions BEFORE rasterization to capture from source PDF.
        // For Secure Rasterization pages, skip entirely.
        var textLayerEntries: [CharacterInfo]? = nil
        var pageDigest: PageFilterDigest? = nil
        // J-12: the text-layer line assembly receives the page's redaction
        // rects (PDF points) so a bridge never crosses one.
        var redactionRectsForTextLayer: [CGRect] = []
        // Effective per-page fallback reason. Starts as the pre-flight
        // reason recorded at build time (non-nil only for fallback pages of a
        // Searchable-mode run); the runtime fallback paths below overwrite it.
        var fallbackReason = page.fallbackReason
        // The text path's count of runs left out (zero unless the path ran).
        var runsLeftOut = 0
        var hiddenTextLines: HiddenTextLines? = nil

        if page.pipelineMode == .searchableRedaction {
            do {
                let characters = try await PageTextPath.extract(page)

                // Check for fallback triggers
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
                    // `preflight`'s geometry read survives). For an un-rotated page
                    // `effectiveSize` equals the cropBox size; the origin is zero.
                    // This one `pageBounds` feeds all FOUR synchronized consumers:
                    // the rect filter, the region shapes,
                    // `redactionRectsForTextLayer` (the bridge check), and
                    // `filterResult.toDigest(redactionRects:)`. Never give the
                    // digest an independent conversion.
                    let pageBounds = CGRect(origin: .zero, size: effectiveSize)
                    // A region over a hidden layer strips under its hidden
                    // glyphs' box too (`textRemovalRects`); the fill below
                    // paints `normalizedRect` alone.
                    // The page's text-path rectangles, by the function the
                    // position check calls too; the plan's boxes fill `boxes`.
                    let points = { (r: CGRect) in normalizedToPDFPageCoordinates(r, pageRect: pageBounds) }
                    let textPathRectangles = TextPathRectangle.forPage(regions: page.regions.map {
                        TextPathRegion(id: $0.id, rect: points($0.normalizedRect),
                                       hiddenLettersRect: $0.textLayerRect.map(points), inkStrips: $0.inkStripRects.map(points))
                    }, boxes: [])
                    let redactionRectsInPoints = textPathRectangles.filter { $0.kind != .underWidenedBox }.map(\.rect)
                    // The frame carries the page's rotation: the drawn-cell
                    // rule, the writer and the lineage digest all work in the
                    // SOURCE frame of a rotated page.
                    let frame = PageFrame(
                        rotation: page.rotation, displayedSize: effectiveSize)
                    // The page's text path: the fold, the filter, the alphabet
                    // marks, the drawn-cell rule and the record, each step
                    // through its seam (`PageTextPath`). Its rectangles are
                    // the text-path rectangles above, every one ordinary
                    // while no box is passed; the fills' rectangles fill
                    // `paintedRectangles`.
                    let path = try await PageTextPath.run(
                        entries: characters, frame: frame, textPathRectangles: textPathRectangles,
                        paintedRectangles: [], pageIndex: page.pageIndex)
                    if path.drawnCellDropped > 0 {
                        pageRasterizerLogger.log(
                            "page \(page.pageIndex): \(path.drawnCellDropped, privacy: .public) surviving character(s) whose drawn cell lay inside a redaction region were dropped from the text layer"
                        )
                    }
                    runsLeftOut = path.runsLeftOut
                    switch path.outcome {
                    case .written(let entries, let digest, let removalRects):
                        textLayerEntries = entries
                        redactionRectsForTextLayer = removalRects
                        pageDigest = digest
                        hiddenTextLines = path.hiddenTextLines
                    case .picture(let reason):
                        // The page is written without a text layer (entries
                        // and digest never set, the reason recorded): the
                        // drawn-cell rule did not settle outside the regions,
                        // a line could not be laid out in the hidden text's
                        // faces, or no word the hidden text can write is left.
                        fallbackReason = reason
                        pageRasterizerLogger.log(
                            "page \(page.pageIndex) fell back to secure rasterization at runtime (the text path ended in a picture: \(String(describing: reason), privacy: .public))"
                        )
                    }
                } else {
                    // shouldFallback or empty: textLayerEntries remains nil,
                    // page processed as Secure Rasterization.
                    // Record which runtime condition it was.
                    fallbackReason = shouldFallback
                        ? .cjkEncodingFailure : .noExtractableText
                    pageRasterizerLogger.log(
                        "page \(page.pageIndex) fell back to secure rasterization at runtime (\(shouldFallback ? "replacement-character ratio" : "empty extraction", privacy: .public))"
                    )
                }
            } catch { // LegalPhrases:safe (Swift keyword)
                // Extraction threw (e.g., OCG defense) — per-page fallback
                // to Secure Rasterization. textLayerEntries remains nil.
                // Record + log the runtime reason (reason text
                // only — no document content).
                fallbackReason = .extractionFailed
                pageRasterizerLogger.log(
                    "page \(page.pageIndex) fell back to secure rasterization at runtime (text extraction threw)"
                )
            }
        }

        return TextLayerState(
            entries: textLayerEntries, digest: pageDigest,
            removalRects: redactionRectsForTextLayer, fallbackReason: fallbackReason,
            runsLeftOut: runsLeftOut, hiddenTextLines: hiddenTextLines
        )
    }

    /// The page drawn at the settled DPI, under the render's timeout.
    private func render(_ page: PDFPageData, raster: Raster) async throws -> CGImage {
        // 3. Render page with timeout
        // CG-only concurrent render path — draw the pre-extracted
        // `cgPage` with the pre-extracted `cropBoxBounds`/`rotation`; the shared
        // `PDFPage` is never touched here.
        guard let cgPage = page.cgPage else {
            throw PipelineError.redactionError(.bitmapCreationFailed(pageIndex: page.pageIndex))
        }
        return try await renderCGPageWithTimeout(
            cgPage, bounds: page.cropBoxBounds, rotation: page.rotation,
            pageIndex: page.pageIndex, dpi: CGFloat(raster.dpi),
            pixelSize: (raster.pixels.width, raster.pixels.height)
        )
    }

    /// 4b. The hidden-text ink test. A Searchable page's
    /// surviving glyphs are read back from the RENDERED pixels — what
    /// the reader will see. A glyph whose pixel box is uniform carries
    /// no visible ink (white-on-white text, an invisible render mode,
    /// a box painted over it); its text layer would re-expose what
    /// the page hides, so the page falls back to Secure HERE — after
    /// the render, before any fill — through the same path as the
    /// pre-render fallbacks: entries and digest dropped, the reason
    /// recorded. The box goes through the fills' own mapping and the
    /// fills' own reader (`hasInklessGlyph`).
    private func inkTest(
        _ textLayer: inout TextLayerState, context ctx: CGContext,
        page: PDFPageData, pageSize effectiveSize: CGSize, content: CGSize
    ) throws {
        if let entries = textLayer.entries,
           try Self.hasInklessGlyph(
               context: ctx, entries: entries, pageSize: effectiveSize,
               rotation: page.rotation, content: content
           ) {
            if Self.inkTestCanRun(context: ctx, pageSize: effectiveSize) {
                textLayer.drop(reason: .hiddenText)
                pageRasterizerLogger.log(
                    "page \(page.pageIndex) fell back to secure rasterization at runtime (hidden text)"
                )
            } else {
                // The test could not run: not known clean, so the secure
                // path, with the reason that reads true for it.
                textLayer.drop(reason: .extractionFailed)
                pageRasterizerLogger.log(
                    "page \(page.pageIndex) fell back to secure rasterization at runtime (the ink test could not run)"
                )
            }
        }
    }

    /// The page's output and its result.
    private func buildOutput(
        _ textLayer: TextLayerState, image redactedImage: CGImage,
        page: PDFPageData, pageSize effectiveSize: CGSize
    ) -> RasterizeResult {
        // Use point dimensions (not pixel) for the PDF media box.
        // The CGImage carries the full pixel resolution; CGPDFContext embeds it
        // at native DPI when drawn into the smaller point-sized rect.
        var output = PageOutput(
            image: redactedImage,
            size: effectiveSize,
            textLayerEntries: textLayer.entries,
            redactionRectsInPoints: textLayer.removalRects,
            rotation: page.rotation,
            runsLeftOut: textLayer.runsLeftOut
        )
        output.hiddenTextLines = textLayer.hiddenTextLines
        return RasterizeResult(pageOutput: output, filterDigest: textLayer.digest,
                               fallbackReason: textLayer.fallbackReason)
    }

    // MARK: - Hidden-text ink test

    /// Whether the ink test has a bitmap to read and a page size to map onto.
    static func inkTestCanRun(context: CGContext, pageSize: CGSize) -> Bool {
        context.data != nil && pageSize.width > 0 && pageSize.height > 0
    }

    /// Pixel-area floor under which a glyph box is not tested (a box this
    /// small at any DPI cannot show a glyph edge either way).
    static let hiddenTextMinimumBoxArea: Int = 4

    /// The ink test behind the `.hiddenText` fallback: true when any
    /// surviving glyph's pixel box is NEAR-UNIFORM — every pixel within
    /// `InkContrastFloor.tolerance` levels of its first on every channel.
    /// White-on-white and invisible-render-mode text read the page colour
    /// throughout; a content-stream box painted over text reads the box
    /// colour throughout; near-white, nearly transparent and nearly covered
    /// text sit inside the band; ink of ordinary contrast breaks it (the
    /// band was set below the faintest inked glyph of a born-digital
    /// census). The box is the glyph's displayed-frame bounds through the
    /// fills' own mapping (`normalizedToFillPixels`: pixel-aligned, a 1-px
    /// halo), read by the floor's band reader over the same BGRA buffer the
    /// fills and the verify loop see. A box wholly outside the visible page shows no ink to the
    /// reader and answers true before any pixel is read; whitespace-lineage
    /// glyphs and boxes under `hiddenTextMinimumBoxArea` are exempt. Each box
    /// is read against `InkContrastFloor.band(forBox:…)`: the narrow band on
    /// clean paper, the wider one where the content around the box is
    /// textured. A letter or digit is also read on its CORE (`InkContrastFloor.glyphCore`): the middle band of
    /// its box across the font's height, without the halo. A box drawn over
    /// the text that stops short of the halo — at the selection rectangle,
    /// at the ink bounds — leaves page colour in the halo but covers the
    /// core, so the core reads uniform (`InkContrastFloor.isCoreNearUniform`)
    /// and the page goes image-only. Cooperative cancellation every
    /// 256 glyphs. A test that cannot run — no bitmap data to read, no page
    /// size to map onto — also answers true: a page that could not be
    /// checked is not known to be clean (`inkTestCanRun` tells the two
    /// apart for the recorded reason).
    static func hasInklessGlyph(
        context: CGContext, entries: [CharacterInfo], pageSize: CGSize, rotation: Int = 0,
        content: CGSize? = nil
    ) throws -> Bool {
        guard inkTestCanRun(context: context, pageSize: pageSize) else {
            return true
        }
        let bitmap = CGRect(x: 0, y: 0, width: context.width, height: context.height)
        let basis = content ?? bitmap.size
        let visiblePage = CGRect(x: 0, y: 0, width: 1, height: 1)
        var band = 0
        for entry in entries {
            band += 1
            if band & 0xFF == 0 { try Task.checkCancellation() }
            if SandwichMetrics.isLineageWhitespace(entry.character) { continue }
            let b = entry.bounds
            let normalized = CGRect(
                x: b.minX / pageSize.width, y: b.minY / pageSize.height,
                width: b.width / pageSize.width, height: b.height / pageSize.height
            )
            if normalized.width > 0, normalized.height > 0, !normalized.intersects(visiblePage) {
                return true
            }
            let box = normalizedToFillPixels(normalized, content: basis).intersection(bitmap)
            guard !box.isEmpty,
                  Int(box.width) * Int(box.height) >= hiddenTextMinimumBoxArea else { continue }
            let band = try InkContrastFloor.band(forBox: box, rotation: rotation, context: context)
            if try InkContrastFloor.isNearUniform(context: context, rect: box, band: band) {
                return true
            }
            if isLetterOrDigit(entry.character),
               let core = InkContrastFloor.glyphCore(normalized, rotation: rotation,
                                    bitmapWidth: context.width, bitmapHeight: context.height,
                                    content: basis),
               Int(core.width) * Int(core.height) >= hiddenTextMinimumBoxArea,
               try InkContrastFloor.isCoreNearUniform(context: context, rect: core, band: band) {
                return true
            }
        }
        return false
    }

    /// One letter or decimal digit, with only its own combining marks after
    /// it: the glyphs with stroke in the middle of their box. A lone mark, a
    /// modifier letter, punctuation, a ligature and an entry recomposed
    /// across a line break are read by the halo test alone.
    static func isLetterOrDigit(_ character: String) -> Bool {
        var scalars = character.unicodeScalars.makeIterator()
        switch scalars.next()?.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .otherLetter, .decimalNumber: break
        default: return false
        }
        while let next = scalars.next() {
            switch next.properties.generalCategory {
            case .nonspacingMark, .spacingMark, .enclosingMark: continue
            default: return false
            }
        }
        return true
    }

    // MARK: - Render with Timeout

    /// CG-only render-with-timeout, used by the concurrent `rasterize`.
    /// Consumes the pre-extracted `CGPDFPage` + geometry, so no shared
    /// `PDFPage` is touched concurrently.
    /// Concurrent-read safety of `CGPDFPage` across tasks is NOT documented by
    /// Apple — it is validated empirically by `PDFKitConcurrencyStressTests`
    /// (TSan, iOS 26 SDK, 2026-06); revalidate on SDK bumps. The other surviving
    /// concurrent PDFKit surfaces are `extractCharacters` (searchable text) and
    /// the OCG `pageReferencesHiddenOCG` `pageRef` walk — both covered by that
    /// harness.
    @concurrent
    func renderCGPageWithTimeout(
        _ cgPage: CGPDFPage, bounds: CGRect, rotation: Int,
        pageIndex: Int, dpi: CGFloat, pixelSize: (width: Int, height: Int)? = nil
    ) async throws -> CGImage {
        // Pre-flight bound-check before entering the render task group —
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
        let size = pixelSize.map { SendablePixelSize(width: $0.width, height: $0.height) }
        return try await withThrowingTaskGroup(of: CGImage.self) { group in
            group.addTask {
                try await self.renderPageFromCGPage(
                    sendableCG.page, bounds: rawBounds, rotation: pageRotation,
                    pageIndex: idx, dpi: targetDPI, pixelSize: size.map { ($0.width, $0.height) }
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

    // MARK: - Core Render

    /// The one render body, over a pre-extracted `CGPDFPage` + PDFKit-sourced
    /// `bounds`/`rotation`, so the concurrent render path never reads the live
    /// `PDFPage`. The box defaults to `.cropBox`, the one the production call
    /// site uses. Handles the box origin,
    /// /Rotate, DPI scaling and the anti-aliasing defense. Rendering is via
    /// CoreGraphics (`drawPDFPage`), never the PDFKit page-level draw API.
    @concurrent
    func renderPageFromCGPage(
        _ cgPage: CGPDFPage, bounds: CGRect, rotation: Int,
        pageIndex: Int, dpi: CGFloat, box: PDFDisplayBox = .cropBox,
        pixelSize: (width: Int, height: Int)? = nil
    ) async throws -> CGImage {
        try Task.checkCancellation()

        let rawRect = bounds

        // Compute post-rotation visual dimensions
        let effectiveSize: CGSize = (rotation == 90 || rotation == 270)
            ? CGSize(width: rawRect.height, height: rawRect.width)
            : rawRect.size

        // The raster's size: the page's own, as `pagePixels` settled it from
        // the page's data, or else by the raster rule from the crop box; the
        // drawing scale stays dpi / 72.
        let scale = dpi / 72.0
        guard let raster = pixelSize ?? Self.rasterPixelSize(bounds: rawRect, rotation: rotation, dpi: dpi) else {
            throw PipelineError.redactionError(.bitmapCreationFailed(pageIndex: pageIndex))
        }
        let pw = raster.width, ph = raster.height

        guard let ctx = createBitmapContext(width: pw, height: ph) else {
            throw PipelineError.redactionError(.bitmapCreationFailed(pageIndex: pageIndex))
        }
        defer { FirstRenderBitmap.release(ctx) } // the first-render bitmap is wiped at its release

        // White background (UIColor on iOS)
        #if canImport(UIKit)
        ctx.setFillColor(UIColor.white.cgColor)
        #else
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        #endif
        ctx.fill(CGRect(x: 0, y: 0, width: pw, height: ph))

        // Security: disable font smoothing (Bland et al. defense)
        ctx.setShouldSmoothFonts(false)
        ctx.setShouldSubpixelQuantizeFonts(false)
        ctx.setAllowsFontSubpixelPositioning(false)

        // The drawing transform in PDFKit's rotation frame (box origin +
        // rotation; see `drawingTransform`).
        let targetRect = CGRect(x: 0, y: 0, width: effectiveSize.width, height: effectiveSize.height)
        let transform = Self.drawingTransform(
            for: cgPage, box: box == .cropBox ? .cropBox : .mediaBox,
            rotation: rotation, targetRect: targetRect
        )

        // DPI scale first, then drawing transform
        ctx.scaleBy(x: scale, y: scale)
        ctx.concatenate(transform)

        // Clip to the box
        let cropBox = cgPage.getBoxRect(box == .cropBox ? .cropBox : .mediaBox)
        ctx.addRect(cropBox)
        ctx.clip()

        // Render using CoreGraphics (NOT PDFKit's draw()).
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

extension PageRasterizer {
    /// The transform that draws `cgPage`'s `box` into `targetRect` in the
    /// rotation frame PDFKit reports (`rotation`, the `PDFPage.rotation`
    /// every region is built in). CoreGraphics' `getDrawingTransform`
    /// applies the page's raw `/Rotate`, which PDFKit rounds when it is not
    /// a right angle; its transform is used only when its matrix is the
    /// quarter turn PDFKit reports — every page the pre-flight admits,
    /// unchanged to the bit. Otherwise the transform is built here: the
    /// cropBox centred on the target, rotated clockwise by `rotation`,
    /// scaled down to fit.
    static func drawingTransform(
        for cgPage: CGPDFPage, box: CGPDFBox, rotation: Int, targetRect: CGRect
    ) -> CGAffineTransform {
        let system = cgPage.getDrawingTransform(
            box, rect: targetRect, rotate: 0, preserveAspectRatio: true)
        let turn = ((rotation % 360) + 360) % 360
        let (a, b, c, d): (CGFloat, CGFloat, CGFloat, CGFloat)
        switch turn {
        case 90: (a, b, c, d) = (0, -1, 1, 0)
        case 180: (a, b, c, d) = (-1, 0, 0, -1)
        case 270: (a, b, c, d) = (0, 1, -1, 0)
        default: (a, b, c, d) = (1, 0, 0, 1)
        }
        // Same quarter turn: every component is zero where the rotation
        // matrix is zero (a -0.0 included) and carries its sign elsewhere;
        // the positive scale does not change either.
        let pairs: [(CGFloat, CGFloat)] = [(system.a, a), (system.b, b), (system.c, c), (system.d, d)]
        if pairs.allSatisfy(Self.sameSignOrZero) { return system }

        let rect = cgPage.getBoxRect(box)
        let quarter = turn == 90 || turn == 270
        let turnedWidth: CGFloat = quarter ? rect.height : rect.width
        let turnedHeight: CGFloat = quarter ? rect.width : rect.height
        let scale: CGFloat = min(targetRect.width / turnedWidth, targetRect.height / turnedHeight, 1)
        let toCentre = CGAffineTransform(translationX: -rect.midX, y: -rect.midY)
        let turned = CGAffineTransform(a: a * scale, b: b * scale, c: c * scale, d: d * scale, tx: 0, ty: 0)
        let toTarget = CGAffineTransform(translationX: targetRect.midX, y: targetRect.midY)
        return toCentre.concatenating(turned).concatenating(toTarget)
    }

    private static func sameSignOrZero(_ pair: (CGFloat, CGFloat)) -> Bool {
        let (value, sign) = pair
        if sign == 0 { return value == 0 }
        return value != 0 && value.sign == sign.sign
    }
}

/// A raster size carried into the render task.
private struct SendablePixelSize: Sendable { let width: Int; let height: Int }
