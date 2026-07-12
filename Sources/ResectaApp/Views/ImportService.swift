import Foundation
import PDFKit
import UIKit
import ImageIO
import CoreGraphics
import RedactionEngine

// UI_UX §5.1–§5.2: Import validation, loading, and image-to-PDF conversion.

enum ImportService {

    // MARK: - Magic-Byte Format Detection (Pkg G.1)

    /// Routing categories recognized by the drop handler. PDF and image
    /// payloads take different validation paths inside `importDocument`;
    /// `unknown` falls back to whatever the entry point can infer.
    ///
    /// TRUST-import-drop-image-deadcode: drag-and-drop previously hardcoded
    /// `suggestedType: "pdf"` on every payload, making the image branch
    /// dead code on the drop entry point. Inspecting magic bytes first
    /// routes JPEG / PNG / HEIC / WEBP payloads to the image branch and
    /// leaves PDFs reaching the PDF branch.
    enum DroppedPayloadKind {
        case pdf
        case image
        case unknown

        /// Suggested-type string accepted by `importDocument(data:suggestedType:...)`.
        /// Inside `validateAndLoad` the suggested type is consulted alongside
        /// the same `%PDF` magic-byte check, so unknown payloads keep the
        /// previous default (`"pdf"`) — the PDF branch's magic-byte sniff
        /// then either accepts the data or routes to the failure path.
        var suggestedType: String {
            switch self {
            case .pdf, .unknown: return "pdf"
            case .image: return "image"
            }
        }
    }

    /// Sniff the leading bytes of a dropped payload to decide which import
    /// branch it should take. See `DroppedPayloadKind` for routing rules.
    ///
    /// Recognized signatures (TRUST-import-drop-image-deadcode):
    /// - `%PDF` (`25 50 44 46`)             → `.pdf`
    /// - JPEG SOI (`FF D8 FF`)              → `.image`
    /// - PNG (`89 50 4E 47`)                → `.image`
    /// - WEBP (`RIFF` + `WEBP` at offset 8) → `.image`
    /// - HEIC (`ftypheic` / `ftyphvc1` at offset 4) → `.image`
    static func detectPayloadKind(from data: Data) -> DroppedPayloadKind {
        // Normalize to a Bytes view rooted at offset 0 so subscript access
        // works regardless of whether `data` is a fresh `Data` or a slice
        // (`Data` indices are not always zero-based).
        //
        // Only the first 12 bytes are inspected below (every branch
        // reads at most byte 11), so copy just those rather than materializing
        // the entire — up to 50 MB — payload into a `[UInt8]`. `prefix` yields
        // a zero-based slice, preserving the offset-0 normalization above.
        let bytes = [UInt8](data.prefix(12))
        // %PDF — 4 bytes
        if bytes.starts(with: [0x25, 0x50, 0x44, 0x46]) { return .pdf }
        // JPEG SOI — first 3 bytes 0xFF 0xD8 0xFF (4th byte is application marker)
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return .image }
        // PNG — 0x89 'P' 'N' 'G'
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return .image }
        // WEBP — RIFF<size>WEBP. Bytes 0..3 = "RIFF", bytes 8..11 = "WEBP".
        if bytes.count >= 12,
           bytes.starts(with: [0x52, 0x49, 0x46, 0x46]),
           bytes[8] == 0x57, bytes[9] == 0x45, bytes[10] == 0x42, bytes[11] == 0x50 {
            return .image
        }
        // HEIC / HEIF — ISO BMFF box: bytes 4..7 = "ftyp", bytes 8..11 = brand.
        // Common still-image brands: heic, heix, hevc, hevx, mif1, msf1, heim, heis, hevm, hevs.
        if bytes.count >= 12,
           bytes[4] == 0x66, bytes[5] == 0x74, bytes[6] == 0x79, bytes[7] == 0x70 {
            let brand: [UInt8] = [bytes[8], bytes[9], bytes[10], bytes[11]]
            let imageBrands: [[UInt8]] = [
                [0x68, 0x65, 0x69, 0x63], // heic
                [0x68, 0x65, 0x69, 0x78], // heix
                [0x68, 0x65, 0x76, 0x63], // hevc
                [0x68, 0x65, 0x76, 0x78], // hevx
                [0x6D, 0x69, 0x66, 0x31], // mif1
                [0x6D, 0x73, 0x66, 0x31], // msf1
                [0x68, 0x65, 0x69, 0x6D], // heim
                [0x68, 0x65, 0x69, 0x73], // heis
                [0x68, 0x65, 0x76, 0x6D], // hevm
                [0x68, 0x65, 0x76, 0x73], // hevs
            ]
            if imageBrands.contains(brand) { return .image }
        }
        return .unknown
    }

    // MARK: - Sendable Bridge Type

    /// Results of off-MainActor PDF validation. All fields are Sendable.
    /// The PDFDocument is wrapped because PDFDocument is not Sendable.
    private struct PDFValidationResult: Sendable {
        let document: SendablePDFDocument
        let textLayerStatus: [Int: TextLayerStatus]
        /// M1: doc-level OCG hidden-layer presence, walked from the CGPDFDocument
        /// built off the raw bytes (PDFDocument(data:) does not retain a
        /// documentURL). Drives `TextLayerExtractor.pageReferencesHiddenOCG`.
        let hasHiddenOCG: Bool
    }

    // MARK: - Import from Security-Scoped URL (Files app, drag-and-drop)

    /// Full import flow from a security-scoped URL.
    /// Transitions: current → .importing → .editing (success) or .failed (error).
    /// Old document state is preserved until validation succeeds.
    /// Async: file I/O runs off MainActor to avoid blocking UI.
    /// CANCEL-006 (Pkg B): the work is wrapped in a stored Task so the
    /// Cancel affordance and scene-phase observer can reach the detached
    /// per-page loops via `documentState.activeImportTask`.
    static func importDocument(
        from url: URL,
        documentState: DocumentState,
        redactionState: RedactionState,
        stripAuxData: Bool = false
    ) async {
        // Pkg D / STATE-1: defensive precondition. The transition table
        // is the canonical authority for "may we enter `.importing` now".
        // If the entry-point view-layer gate was bypassed (programmatic
        // call, race against a pipeline start), refuse to mutate
        // `redactionState.clearForNewDocument()` and
        // `documentState.sourceDocument` before this import knows it
        // owns the slot.
        guard documentState.canStartImport else { return }

        guard url.startAccessingSecurityScopedResource() else {
            documentState.transition(to: .importing)
            documentState.transition(to: .failed(
                error: .importError(.corrupt),
                returnPhase: .empty
            ))
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }

        let returnPhase: DocumentState.ReturnPhase =
            documentState.phaseKind == .editing ? .editing : .empty

        guard documentState.transition(to: .importing) else { return }

        // CANCEL-006: register a child Task on `activeImportTask` so
        // `cancelActivePipeline` reaches the detached per-page loops via
        // the `Task.checkCancellation()` calls in `validatePDFOffMainActor`.
        // `withTaskCancellationHandler` propagates the caller's cancellation
        // signal (e.g., the scene-phase observer's call) to `workTask`.
        //
        // nonisolated(unsafe): @Observable prevents Sendable; Task captures
        // the references implicitly. Safe because all access is on MainActor
        // (mirrors the `PipelineCoordinator` Task-dispatch pattern).
        let pathExtension = url.pathExtension
        nonisolated(unsafe) let docState = documentState
        nonisolated(unsafe) let redactState = redactionState
        let workTask = Task<Void, Never> { @MainActor in
            await runImport(
                data: nil,
                url: url,
                suggestedType: pathExtension,
                returnPhase: returnPhase,
                documentState: docState,
                redactionState: redactState,
                stripAuxData: stripAuxData
            )
        }
        documentState.activeImportTask = workTask
        await withTaskCancellationHandler {
            await workTask.value
        } onCancel: {
            workTask.cancel()
        }
        // Cleared inside `cancelActivePipeline`'s `.importing` branch on
        // user-initiated cancel; this nil-out covers the success / failure
        // paths where the task ran to completion.
        if documentState.activeImportTask == workTask {
            documentState.activeImportTask = nil
        }
    }

    // MARK: - Import from Raw Data (Photos, drag-and-drop)

    /// Full import flow from in-memory data.
    /// Async for consistency with URL-based import; validation runs on MainActor.
    /// CANCEL-006: same Task-registration pattern as the URL variant.
    static func importDocument(
        data: Data,
        suggestedType: String,
        documentState: DocumentState,
        redactionState: RedactionState,
        stripAuxData: Bool = false
    ) async {
        // Pkg D / STATE-1: defensive precondition mirrors the URL-based
        // overload above. See comment there for the rationale.
        guard documentState.canStartImport else { return }

        let returnPhase: DocumentState.ReturnPhase =
            documentState.phaseKind == .editing ? .editing : .empty

        guard documentState.transition(to: .importing) else { return }

        // nonisolated(unsafe): see comment in the URL variant above.
        nonisolated(unsafe) let docState = documentState
        nonisolated(unsafe) let redactState = redactionState
        let workTask = Task<Void, Never> { @MainActor in
            await runImport(
                data: data,
                url: nil,
                suggestedType: suggestedType,
                returnPhase: returnPhase,
                documentState: docState,
                redactionState: redactState,
                stripAuxData: stripAuxData
            )
        }
        documentState.activeImportTask = workTask
        await withTaskCancellationHandler {
            await workTask.value
        } onCancel: {
            workTask.cancel()
        }
        if documentState.activeImportTask == workTask {
            documentState.activeImportTask = nil
        }
    }

    // MARK: - Inner Work (Cancellation-aware)

    /// Shared work body for both `importDocument` variants. Runs inside the
    /// task stored on `documentState.activeImportTask` so cancellation
    /// reaches the detached per-page validation loops.
    @MainActor
    private static func runImport(
        data: Data?,
        url: URL?,
        suggestedType: String,
        returnPhase: DocumentState.ReturnPhase,
        documentState: DocumentState,
        redactionState: RedactionState,
        stripAuxData: Bool
    ) async {
        do {
            let loadedData: Data
            if let data {
                loadedData = data
            } else if let url {
                // Offload file I/O to avoid blocking MainActor. Cancellation
                // is propagated to the detached read via `withTaskCancellationHandler`.
                let readTask = Task.detached { try Data(contentsOf: url) }
                loadedData = try await withTaskCancellationHandler {
                    try await readTask.value
                } onCancel: {
                    readTask.cancel()
                }
            } else {
                throw PipelineError.importError(.corrupt)
            }
            try await validateAndLoad(
                data: loadedData,
                suggestedType: suggestedType,
                documentState: documentState,
                redactionState: redactionState,
                stripAuxData: stripAuxData
            )
        } catch is CancellationError { // LegalPhrases:safe (Swift keyword)
            // CANCEL-006: cooperative cancellation surrenders silently —
            // `cancelActivePipeline` has already transitioned the phase to
            // `.empty`. Adding a failed-transition here would duplicate
            // the user-initiated cancel.
            return
        } catch let error as PipelineError { // LegalPhrases:safe (Swift keyword)
            // Defensive path: PDFKit / loadImage may surface a typed error
            // on rare timing before the cancellation propagates back.
            guard documentState.phaseKind == .importing else { return }
            documentState.transition(to: .failed(error: error, returnPhase: returnPhase))
        } catch { // LegalPhrases:safe (Swift keyword)
            if error is CancellationError { return }
            guard documentState.phaseKind == .importing else { return }
            documentState.transition(to: .failed(
                error: .importError(.corrupt),
                returnPhase: returnPhase
            ))
        }
    }

    // MARK: - Validation and Loading (UI_UX §5.2)

    /// Validate document data and load into state. Throws on validation failure.
    /// Old state is preserved until validation succeeds — clearing happens only
    /// after we confirm the new document is valid.
    /// PDF validation runs off MainActor via Task.detached to avoid blocking UI.
    private static func validateAndLoad(
        data: Data,
        suggestedType: String,
        documentState: DocumentState,
        redactionState: RedactionState,
        stripAuxData: Bool
    ) async throws {
        // Size check — 50 MB practical limit based on memory budget
        let maxSize = 50 * 1024 * 1024
        guard data.count <= maxSize else {
            throw PipelineError.importError(.tooLarge(bytesRead: data.count))
        }

        // PDF magic bytes: %PDF
        let isPDF = suggestedType.lowercased() == "pdf"
            || data.starts(with: [0x25, 0x50, 0x44, 0x46])

        if isPDF {
            // Offload all CPU-intensive PDF work off MainActor.
            // CANCEL-006: cancellation propagates from the outer
            // `activeImportTask` via `withTaskCancellationHandler` to the
            // detached task, which observes it through the
            // `Task.checkCancellation()` calls in `validatePDFOffMainActor`.
            let detached = Task.detached {
                try validatePDFOffMainActor(data: data)
            }
            let result = try await withTaskCancellationHandler {
                try await detached.value
            } onCancel: {
                detached.cancel()
            }

            // CANCEL-006: re-check cancellation before mutating state —
            // a cancel signal arriving between the detached task's return
            // and this point should not produce a half-loaded document.
            try Task.checkCancellation()

            // Back on MainActor — apply validated results to state
            redactionState.clearForNewDocument()
            documentState.sourceDocument = result.document.document
            documentState.currentPageIndex = 0
            documentState.textLayerStatus = result.textLayerStatus
            documentState.sourceHasHiddenOCG = result.hasHiddenOCG
            documentState.lastUsedPipelineMode = nil
            documentState.wasPausedByBackground = false
            documentState.pausedFromPhase = nil  // clear alongside wasPausedByBackground
            documentState.transition(to: .editing)
        } else {
            // Offload image decode + PDF render off MainActor (matches PDF branch).
            // SEC-8 prereq: when `stripAuxData` is true, the import path runs the
            // Live Photo / Portrait depth aux-metadata stripper before the PDF
            // render. Default is false (no behavior change in this PR); SEC-8
            // flips the flag when paranoid mode is enabled.
            // CANCEL-006: same cancellation propagation as the PDF branch.
            let detached = Task.detached {
                try loadImageOffMainActor(data: data, stripAuxData: stripAuxData)
            }
            let sendableDoc = try await withTaskCancellationHandler {
                try await detached.value
            } onCancel: {
                detached.cancel()
            }

            try Task.checkCancellation()

            // Back on MainActor — apply validated results to state
            redactionState.clearForNewDocument()
            documentState.sourceDocument = sendableDoc.document
            documentState.currentPageIndex = 0
            documentState.textLayerStatus = [:]
            documentState.sourceHasHiddenOCG = false
            documentState.lastUsedPipelineMode = nil
            documentState.wasPausedByBackground = false
            documentState.pausedFromPhase = nil  // clear alongside wasPausedByBackground
            // Image imports have no text layer — status stays empty
            documentState.transition(to: .editing)
        }
    }

    // MARK: - Off-MainActor PDF Validation

    /// Perform all CPU-intensive PDF validation off MainActor.
    /// nonisolated: explicitly opted out of SE-0466 MainActor default to avoid blocking UI.
    private nonisolated static func validatePDFOffMainActor(data: Data) throws -> PDFValidationResult {
        guard let doc = PDFDocument(data: data) else {
            throw PipelineError.importError(.corrupt)
        }
        guard !doc.isLocked else {
            throw PipelineError.importError(.passwordProtected)
        }
        guard doc.pageCount > 0 else {
            throw PipelineError.importError(.corrupt)
        }
        // Page count cap — a minimal PDF can have thousands of pages within
        // the 50 MB size limit, causing excessive memory and processing time.
        guard doc.pageCount <= 500 else {
            throw PipelineError.importError(.tooLarge(bytesRead: data.count))
        }

        // Per-page dimension validation (ENGINE §2.6).
        // CANCEL-006 (Pkg B): per-iteration `Task.checkCancellation()` so a
        // 500-page document surrenders cooperatively when the outer
        // `activeImportTask` is cancelled by the Cancel button or the
        // scene-phase observer's `cancelActivePipeline` call.
        for i in 0..<doc.pageCount {
            try Task.checkCancellation()
            guard let page = doc.page(at: i) else {
                // Inaccessible pages in a valid PDF indicate corruption or
                // malicious crafting — fail rather than silently skip.
                throw PipelineError.importError(.corrupt)
            }
            let box = page.bounds(for: .cropBox)
            // N3: CGRect auto-standardizes negative dimensions to positive.
            // PDFKit bounds(for:) always returns non-negative. Documented for awareness.
            guard box.width > 0, box.height > 0,
                  box.width <= 5000, box.height <= 5000 else {
                throw PipelineError.importError(.invalidPageDimensions(pageIndex: i))
            }
        }

        // Early rejection of PDFs with active content. Also checked in
        // verification Layer 4, but PDFKit parses the document during import
        // so we reject upfront to avoid loading malicious payloads.
        //
        // M1: while we have a CGPDFDocument open, also walk
        // /OCProperties/D/OFF for hidden Optional Content Groups. The engine
        // cannot do this later because PDFDocument(data:) leaves
        // documentURL == nil; computing it here once threads through into
        // every PDFPageData via DocumentState.sourceHasHiddenOCG.
        var hasHiddenOCG = false
        if let provider = CGDataProvider(data: data as CFData),
           let cgDoc = CGPDFDocument(provider),
           let catalog = cgDoc.catalog {
            let dangerousKeys = ["JavaScript", "JS", "Launch"]
            for key in dangerousKeys {
                var obj: CGPDFObjectRef?
                if CGPDFDictionaryGetObject(catalog, key, &obj) {
                    throw PipelineError.importError(.corrupt)
                }
            }
            hasHiddenOCG = TextLayerExtractor.documentHasHiddenOCG(cgDoc)
        }

        // Detect text layers per page — can be slow for complex PDFs,
        // which is why this runs off MainActor.
        // CANCEL-006: per-iteration `Task.checkCancellation()` mirrors the
        // dimension-validation loop above; both contribute to the worst-case
        // surrender latency on a multi-hundred-page document.
        var textLayerStatus: [Int: TextLayerStatus] = [:]
        for i in 0..<doc.pageCount {
            try Task.checkCancellation()
            guard let page = doc.page(at: i) else { continue }
            textLayerStatus[i] = TextLayerDetector.detectTextLayer(page)
        }

        return PDFValidationResult(
            document: SendablePDFDocument(doc),
            textLayerStatus: textLayerStatus,
            hasHiddenOCG: hasHiddenOCG
        )
    }

    // MARK: - Off-MainActor Image Decode and PDF Render

    /// Decode an image blob and wrap it as a single-page PDFDocument off MainActor.
    /// nonisolated: explicitly opted out of SE-0466 MainActor default so the
    /// `UIImage(data:)` decode and `UIGraphicsPDFRenderer.pdfData` call do not
    /// block the UI on large photos (ARCH §3.3).
    private nonisolated static func loadImageOffMainActor(
        data: Data,
        stripAuxData: Bool
    ) throws -> SendablePDFDocument {
        guard let image = UIImage(data: data) else {
            throw PipelineError.importError(.unsupportedFormat)
        }
        // Cap at 5000×5000 to match PDF page dimension limits (ENGINE §2.6).
        // A 50 MB JPEG can decompress to enormous bitmaps (e.g., 20000×20000 = 1.6 GB).
        //
        // Pkg G.1 / TRUST-import-image-pixel-vs-point-cap: the cap is on the
        // backing bitmap size, not the layout-point size. UIImage.size returns
        // POINTS (size = pixels / scale). A `scale: 3.0` image at 4000×4000 pt
        // is 12000×12000 px = 144 MP; the point check would let it through
        // and the renderer would allocate ~575 MB to draw it. Prefer the
        // cgImage's pixel dimensions; fall back to size × scale when the
        // CIImage-backed path makes cgImage nil.
        let pixelWidth: CGFloat
        let pixelHeight: CGFloat
        if let cgImage = image.cgImage {
            pixelWidth = CGFloat(cgImage.width)
            pixelHeight = CGFloat(cgImage.height)
        } else {
            pixelWidth = image.size.width * image.scale
            pixelHeight = image.size.height * image.scale
        }
        guard pixelWidth <= 5000, pixelHeight <= 5000 else {
            throw PipelineError.importError(.invalidPageDimensions(pageIndex: 0))
        }

        // SEC-8 prereq hook (default off): when `stripAuxData` is true, run the
        // LivePhotoAuxStripper across the image's property dictionary. V1 strips
        // the dict only — the CGImage is returned unchanged. The PDF render
        // below does not propagate ImageIO property dictionaries, so the V1
        // contract here is "the helper executed and dropped aux keys" rather
        // than "the output PDF would otherwise have contained them." SEC-8
        // (unit 23) flips the gate when paranoid mode is enabled.
        if stripAuxData, let cgImage = image.cgImage,
           let source = CGImageSourceCreateWithData(data as CFData, nil) {
            let rawProperties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                ?? ([:] as CFDictionary)
            let stripper = LivePhotoAuxStripper()
            _ = stripper.strip(cgImage, properties: rawProperties)
            // The stripped CGImage / properties dict is intentionally discarded:
            // V1 only verifies the helper ran on the import path. Discarding the
            // stripped output is harmless because `renderImageAsPDF` below
            // rebuilds the page from a fresh bitmap (UIGraphicsImageRenderer),
            // which drops ALL ImageIO metadata — the source EXIF/GPS cannot
            // reach the output PDF regardless of this branch.
            //
            // (HISTORY: an earlier render path
            // drew the ORIGINAL `image`, so UIGraphicsPDFRenderer embedded the
            // source JPEG's APP1/EXIF — incl. GPS — into the PDF and the discard
            // was NOT equivalent. The render boundary was rewritten to strip
            // metadata; `LivePhotoAuxStripperTests.testRenderedPDFHasNoEXIF` now
            // guards it as a hard assertion.)
        }

        let pdfData = renderImageAsPDF(image)
        guard let doc = PDFDocument(data: pdfData) else {
            throw PipelineError.importError(.corrupt)
        }
        return SendablePDFDocument(doc)
    }

    // MARK: - Image to PDF Conversion

    /// Convert a UIImage to a single-page PDF document.
    /// nonisolated: called from `loadImageOffMainActor` on the cooperative thread pool.
    private nonisolated static func renderImageAsPDF(_ image: UIImage) -> Data {
        let bounds = CGRect(origin: .zero, size: image.size)   // points: orientation-aware
        // Redraw the decoded image into a FRESH bitmap before
        // embedding it. UIGraphicsPDFRenderer would otherwise embed the source
        // JPEG verbatim (APP1/EXIF incl. GPS, IPTC, TIFF, XMP, MakerApple) as a
        // DCTDecode stream. Rendering through UIGraphicsImageRenderer drops ALL
        // ImageIO metadata and bakes `imageOrientation` upright, so the page is
        // built from pixels only — no source metadata can survive into the PDF.
        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = image.scale                             // preserve native pixels
        let flat = UIGraphicsImageRenderer(bounds: bounds, format: format).image { _ in
            image.draw(in: bounds)                             // UIKit applies imageOrientation
        }
        let renderer = UIGraphicsPDFRenderer(bounds: bounds)
        return renderer.pdfData { ctx in
            ctx.beginPage()
            flat.draw(in: bounds)                              // `flat` carries no EXIF/GPS
        }
    }

    // MARK: - Sample Document Loading (ARCH §10.4)

    /// Load a bundled sample document. C11: Single SampleDocument.pdf in Resources/.
    static func loadSampleDocument(
        named name: String = "SampleDocument",
        documentState: DocumentState,
        redactionState: RedactionState
    ) async {
        // C11: v1.0 ships one sample document — no subdirectory needed.
        guard let url = Bundle.main.url(
            forResource: name, withExtension: "pdf"
        ) else {
            assertionFailure("Sample document '\(name).pdf' not found in bundle")
            // Graceful degradation in release: show error instead of silent failure
            documentState.transition(to: .importing)
            documentState.transition(to: .failed(
                error: .importError(.corrupt),
                returnPhase: .empty
            ))
            return
        }
        guard let data = try? Data(contentsOf: url) else {
            assertionFailure("Sample document '\(name).pdf' could not be read")
            documentState.transition(to: .importing)
            documentState.transition(to: .failed(
                error: .importError(.corrupt),
                returnPhase: .empty
            ))
            return
        }
        await importDocument(
            data: data, suggestedType: "pdf",
            documentState: documentState, redactionState: redactionState
        )
    }
}
