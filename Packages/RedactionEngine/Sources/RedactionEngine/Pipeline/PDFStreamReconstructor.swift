import CoreGraphics
import Foundation
import ImageIO

// ENGINE §5.1–§5.4 — Streaming page-at-a-time PDF reconstruction.

/// Dedicated actor for PDF reconstruction. Serializes JPEG encoding and PDF
/// writes so the rest of the pipeline can stay on its own actor.
///
/// **Streaming model (CND-11, launch-fix-v2 S5).** Each `appendPage` JPEG-
/// encodes its page and draws it straight into a single `CGPDFContext`, then
/// releases the bytes — so live memory is O(1) in page count rather than
/// O(pages × JPEG). The context is opened lazily on the first appended page
/// (its media box pinned to `firstPageSize`); `finalize` only closes it and
/// applies file protection. This supersedes the earlier PERF-1 buffer-then-
/// write model, whose sole reason to retain every encoded page was the
/// now-removed `replacePage(at:with:)` swap. The production per-page
/// verification retry re-rasterizes and re-appends *before* a page is drawn,
/// so it never needed post-hoc replacement. The output bytes do not change:
/// `CGPDFContext` re-encodes each drawn image independently of when it is
/// drawn, and pages are still drawn in 0..<count append order, so the PDF, its
/// metadata, and the atomic-rename pattern match the prior model byte-for-byte.
///
/// Atomicity: the temp file at `tempURL` is created on the first `appendPage`
/// and completed by `finalize`. The caller performs an atomic rename via
/// `FileManager.replaceItemAt` after `finalize()` returns; on any earlier
/// error its `defer` removes the partial temp file. See ENGINE §5.1.
public actor PDFStreamReconstructor {
    private let tempURL: URL
    private var firstPageSize: CGSize?
    /// The single output PDF context, opened lazily by `openContextIfNeeded()`
    /// on the first appended page and closed by `finalize()`. `nil` before the
    /// first page and after finalize. Held as actor state (non-Sendable, but
    /// the actor provides the isolation) so each `appendPage` can draw and
    /// release its page immediately instead of retaining a buffer.
    private var context: CGContext?
    private var finalized: Bool = false

    /// Count of pages handed to `appendPage` / the test seam, drawn or not.
    /// `pageCount` exposes it; the coordinator tracks the appended count
    /// separately and compares it against `writtenPageCount`.
    private var _appendedPageCount = 0

    /// Count of pages actually drawn into the
    /// PDF context. Each `appendPage` draws exactly one page unless the per-page
    /// decode guard drops it; a not-begun guard or a context-creation failure
    /// also leaves this below the appended count. The coordinator compares it
    /// against the appended count as a postcondition before the atomic rename,
    /// so a truncated temp file never replaces a good output.
    private var _writtenPageCount = 0
    public var writtenPageCount: Int { _writtenPageCount }

    /// One page's data, produced by `encodeBufferedPage` (or the test seam) and
    /// consumed immediately by `drawBufferedPage`. JPEG bytes are encoded so the
    /// source CGImage can be released back to the caller's autoreleasepool; the
    /// value is transient and never retained past the draw.
    private struct BufferedPage {
        let jpegData: Data
        let size: CGSize
        let textLayerEntries: [CharacterInfo]?
        let redactionRectsInPoints: [CGRect]
    }

    public init(tempURL: URL) {
        self.tempURL = tempURL
    }

    // Note: finalize() MUST be called before deallocation to produce a valid
    // PDF. The temp file is created on the first appendPage (when the context
    // opens) and completed by finalize; on error paths the caller's defer block
    // deletes whatever partial temp file exists, so an incomplete PDF on disk
    // is acceptable.

    /// Begin a new PDF document. The first page size pins the initial media box
    /// passed to `CGContext` when it opens on the first appendPage; subsequent
    /// pages specify their own size per-page.
    /// Empty auxiliary dictionary omits /Author, /Title, /Subject,
    /// /Keywords, /Creator. /Producer, /CreationDate, /ModDate are
    /// auto-injected by CGPDFContext (§5.4).
    public func begin(firstPageSize: CGSize) throws {
        guard !finalized else {
            throw PipelineError.redactionError(.reconstructionFailed)
        }
        self.firstPageSize = firstPageSize
    }

    /// Append a single page: JPEG-encode the image at quality 0.92
    /// (ENGINE §5.3), then draw it straight into the (lazily opened) PDF
    /// context together with any invisible text-layer entries (Searchable
    /// Redaction). The encoded bytes are released as the draw returns, so
    /// nothing is retained between pages. Throws if `begin` has not run, the
    /// stream is already finalized, or the JPEG encode fails; a context-
    /// creation or decode failure is non-throwing and instead leaves
    /// `writtenPageCount` behind for the coordinator's postcondition to detect.
    public func appendPage(_ output: PageOutput) throws {
        guard firstPageSize != nil, !finalized else {
            throw PipelineError.redactionError(.reconstructionFailed)
        }
        let buffered = try Self.encodeBufferedPage(from: output)
        drawBufferedPage(buffered)
        _appendedPageCount += 1
    }

    /// Number of pages handed to `appendPage` (test/debug aid; production
    /// callers track this separately). Counts appended pages drawn or not, so
    /// it stays comparable to `writtenPageCount`.
    public var pageCount: Int { _appendedPageCount }

    /// Test seam: hand a page to the draw path directly from raw
    /// bytes, bypassing JPEG encoding, so the per-page decode-guard drop path
    /// is reachable from a test without a genuinely-undecodable `CGImage`.
    /// `internal` — visible only to `@testable` test builds, never to the
    /// production app module.
    func appendUnencodedPageForTesting(jpegData: Data, size: CGSize) {
        drawBufferedPage(BufferedPage(
            jpegData: jpegData, size: size,
            textLayerEntries: nil, redactionRectsInPoints: []))
        _appendedPageCount += 1
    }

    /// Open the output PDF context lazily, pinned to `firstPageSize`'s media
    /// box. Returns the already-open context on later calls, or `nil` if
    /// `begin` has not run, the stream is finalized, or `CGContext` creation
    /// fails. The first successful call creates the temp file at `tempURL`.
    private func openContextIfNeeded() -> CGContext? {
        if let context { return context }
        guard !finalized, let firstSize = firstPageSize else { return nil }
        var box = CGRect(origin: .zero, size: firstSize)
        guard let ctx = CGContext(
            tempURL as CFURL,
            mediaBox: &box,
            [:] as CFDictionary  // ENGINE §5.4: empty aux dict strips most metadata
        ) else { return nil }
        context = ctx
        return ctx
    }

    /// Draw one page into the PDF context inside its own autoreleasepool, then
    /// let the JPEG bytes go. Increments `writtenPageCount` only when a full
    /// draw cycle completes. The autoreleasepool closure keeps `ctx`
    /// as a local and does not reference `self`: capturing self would "send"
    /// the non-Sendable `ctx` into an actor-isolated closure under Swift 6
    /// strict concurrency, so the count is bumped outside the closure.
    private func drawBufferedPage(_ page: BufferedPage) {
        guard let ctx = openContextIfNeeded() else { return }
        let didWrite: Bool = autoreleasepool {
            // Decode the buffered JPEG. EXP-010 (HW-REFUTED): CGPDFContext
            // re-encodes any drawn image, so passthrough is not preserved in
            // the output stream — but the output bytes do not depend on when a
            // page is drawn, so draw-on-append matches the prior buffer-then-
            // write model. The ~3.4ms decode overhead is paid once per page
            // either way.
            guard let provider = CGDataProvider(data: page.jpegData as CFData),
                  let jpegImage = CGImage(
                      jpegDataProviderSource: provider,
                      decode: nil, shouldInterpolate: true,
                      intent: .defaultIntent
                  ) else { return false }

            let pageBox = CGRect(origin: .zero, size: page.size)
            #if canImport(UIKit)
            ctx.beginPDFPage([
                kCGPDFContextMediaBox: NSValue(cgRect: pageBox)
            ] as CFDictionary)
            #else
            // macOS tooling destination: NSValue(cgRect:) is the UIKit
            // spelling; NSRect == CGRect here so NSValue(rect:) is identical.
            ctx.beginPDFPage([
                kCGPDFContextMediaBox: NSValue(rect: pageBox)
            ] as CFDictionary)
            #endif

            ctx.draw(jpegImage, in: pageBox)

            // Invisible text layer for Searchable Redaction (ENGINE §5C).
            // Drawing order: image first, then invisible text on top.
            // Matches standard sandwich PDF structure (ISO 32000, §5C.3).
            if let entries = page.textLayerEntries, !entries.isEmpty {
                TextLayerReconstructor.drawInvisibleTextLayer(
                    context: ctx,
                    entries: entries,
                    pageWidth: page.size.width,
                    redactionRects: page.redactionRectsInPoints
                )
            }

            ctx.endPDFPage()
            return true
        }
        // The decode guard above returns false when a page's JPEG fails to
        // decode, so a dropped page is never counted (writtenPageCount postcondition).
        if didWrite { _writtenPageCount += 1 }
    }

    /// Close the PDF context and apply file protection. Pages were already
    /// drawn by `appendPage`, so this only finishes the stream. If `begin` ran
    /// but no page was appended, the context is opened here and closed empty,
    /// matching the prior model's zero-page output. After `finalize` returns
    /// the file at `tempURL` is complete and the caller performs the atomic
    /// rename to the final output URL.
    public func finalize() {
        guard !finalized, let ctx = openContextIfNeeded() else { return }
        finalized = true

        ctx.closePDF()
        context = nil

        // SEC-1: apply `.complete` file protection to the finalized temp
        // file. PipelineCoordinator.downgradeTempProtectionOnSessionClose()
        // downgrades the whole session subtree to
        // `.completeUntilFirstUserAuthentication` on document close via
        // `TempFileHardening.downgradeTree(at:to:)`. Best-effort:
        // errors here are non-fatal — caller's defer block removes the temp
        // file on failure, and an unprotected file is no worse than the
        // prior contract. We deliberately do NOT throw.
        try? TempFileHardening.applyProtection(tempURL, level: .complete)
    }

    // MARK: - JPEG Encoding (ENGINE §5.3, EXP-007)

    /// Encode the page's `CGImage` to JPEG (q=0.92) and return a fully
    /// populated `BufferedPage`. Failure throws `reconstructionFailed`.
    /// Nonisolated `static` so the actor can call it without re-entering
    /// itself; the work is pure data transformation.
    private static func encodeBufferedPage(from output: PageOutput) throws -> BufferedPage {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data, "public.jpeg" as CFString, 1, nil
        ) else {
            throw PipelineError.redactionError(.reconstructionFailed)
        }
        CGImageDestinationAddImage(dest, output.image, [
            kCGImageDestinationLossyCompressionQuality: 0.92
        ] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw PipelineError.redactionError(.reconstructionFailed)
        }
        return BufferedPage(
            jpegData: data as Data,
            size: output.size,
            textLayerEntries: output.textLayerEntries,
            redactionRectsInPoints: output.redactionRectsInPoints
        )
    }
}

// MARK: - Temp File Cleanup (ARCH §11, MP-5-1)

/// Clean orphaned temp files from prior sessions. Called once at app launch.
/// Crash-loop scenarios can accumulate large temp files before iOS purges them.
///
/// Known temp entry prefixes (keep in sync with producers):
/// - `recon_`              : intermediate reconstruction temp (legacy path; still
///                             created until SEC-2 routing is fully migrated)
/// - `redacted_`           : pipeline output + export copies (legacy flat path)
/// - `redacted_session_`   : SEC-2 per-session subdirectory (entire subtree
///                             removed on session end; this sweep handles the
///                             crash-orphaned remainder)
/// - `resecta_`            : RES-02 broadened sweep — also matches all
///                             `resecta_*` temp writes (e.g.
///                             `resecta_audit_*`, `resecta_coverage_*` from
///                             `MatchExportService`, and any future
///                             `resecta_verification_*` writes). Applies the
///                             same 1-hour TTL and SEC-1 cleanup contract
///                             uniformly so app-kill during a share-sheet
///                             dismiss does not leak orphans.
public func cleanOrphanedTempFiles() {
    let tmp = FileManager.default.temporaryDirectory
    guard let contents = try? FileManager.default.contentsOfDirectory(
        at: tmp, includingPropertiesForKeys: [.creationDateKey]
    ) else { return }
    let staleThreshold = Date().addingTimeInterval(-3600) // 1 hour (ARCH §11)
    for url in contents where url.lastPathComponent.hasPrefix("recon_")
                            || url.lastPathComponent.hasPrefix("redacted_")
                            || url.lastPathComponent.hasPrefix("resecta_") {
        // `redacted_session_<UUID>` directories are caught by the
        // `redacted_` prefix match above; removeItem handles both files
        // and directories recursively. The `resecta_` arm covers
        // `resecta_audit_*` and `resecta_coverage_*` share-sheet temp
        // files written by `MatchExportService` (RES-02).
        if let date = try? url.resourceValues(forKeys: [.creationDateKey]).creationDate,
           date < staleThreshold {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
