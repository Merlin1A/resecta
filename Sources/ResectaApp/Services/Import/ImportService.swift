import Foundation
import PDFKit
import CoreGraphics
import RedactionEngine

// Import validation and loading.

enum ImportService {

    // MARK: - Magic-Byte Format Detection

    /// What the leading bytes of a payload say it is. Resecta opens PDF
    /// files only: an `image` payload is refused before any decode; `pdf`
    /// and `unknown` payloads reach the PDF parser, which decides.
    enum DroppedPayloadKind {
        case pdf
        case image
        case unknown

        /// The type label handed to `importDocument(data:suggestedType:...)`.
        /// Routing reads the bytes, never this label.
        var suggestedType: String {
            switch self {
            case .pdf, .unknown: return "pdf"
            case .image: return "image"
            }
        }
    }

    /// Sniff the leading bytes of a payload to decide whether it may enter
    /// the PDF path. See `DroppedPayloadKind` for the routing rule.
    ///
    /// Recognized signatures:
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

    /// The drop door: whether a dropped payload may enter the import path.
    /// Resecta opens PDF files only, so a payload whose leading bytes carry
    /// an image signature is refused before dispatch. `%PDF` and unknown
    /// payloads are admitted: an unknown payload reaches the PDF parser,
    /// which reports anything it cannot open as an unsupported format
    /// (refusing unknown bytes would also refuse a PDF whose `%PDF` header
    /// is not at offset 0).
    static func admitsDroppedPayload(_ data: Data) -> Bool {
        detectPayloadKind(from: data) != .image
    }

    // MARK: - Sendable Bridge Type

    /// Results of off-MainActor PDF validation. All fields are Sendable.
    /// The PDFDocument is wrapped because PDFDocument is not Sendable.
    private struct PDFValidationResult: Sendable {
        let document: SendablePDFDocument
        let textLayerStatus: [Int: TextLayerStatus]
        /// Doc-level OCG hidden-layer presence, walked from the CGPDFDocument
        /// built off the raw bytes (PDFDocument(data:) does not retain a
        /// documentURL). Drives `TextLayerExtractor.pageReferencesHiddenOCG`.
        let hasHiddenOCG: Bool
        /// Non-Widget source annotations, one entry per subtype, from the
        /// engine's `AnnotationAnalyzer`. Drives the import notice banner:
        /// annotations are drawn by the on-screen PDFKit view but are not
        /// part of the page content stream the export raster is built
        /// from, so their presence is surfaced to the user at import.
        let annotationFindings: [PDFFinding]
        /// Widget annotations whose field carries a value, counted by
        /// `ImportAnnotationNoticeBanner.filledFormFieldCount(in:)`. The
        /// analyzer skips widgets; the viewer draws their values and the
        /// export raster does not carry them, so the count feeds the same
        /// import notice.
        let filledFormFieldCount: Int
    }

    // MARK: - Import from Security-Scoped URL (Files app, drag-and-drop)

    /// Full import flow from a security-scoped URL.
    /// Transitions: current → .importing → .editing (success) or .failed (error).
    /// Old document state is preserved until validation succeeds.
    /// Async: file I/O runs off MainActor to avoid blocking UI.
    /// The work is wrapped in a stored Task so the Cancel affordance and
    /// scene-phase observer can reach the detached per-page loops via
    /// `documentState.activeImportTask`.
    static func importDocument(
        from url: URL,
        documentState: DocumentState,
        redactionState: RedactionState
    ) async {
        // Defensive precondition. The transition table
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

        // Registers a child Task on `activeImportTask` so
        // `cancelActivePipeline` reaches the detached per-page loops via
        // the `Task.checkCancellation()` calls in `validatePDFOffMainActor`.
        // `withTaskCancellationHandler` propagates the caller's cancellation
        // signal (e.g., the scene-phase observer's call) to `workTask`.
        //
        // nonisolated(unsafe): @Observable prevents Sendable; Task captures
        // the references implicitly. Safe because all access is on MainActor
        // (mirrors the `PipelineCoordinator` Task-dispatch pattern).
        nonisolated(unsafe) let docState = documentState
        nonisolated(unsafe) let redactState = redactionState
        let workTask = Task<Void, Never> { @MainActor in
            await runImport(
                data: nil,
                url: url,
                returnPhase: returnPhase,
                documentState: docState,
                redactionState: redactState
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
    /// Same Task-registration pattern as the URL variant. `suggestedType` is
    /// the type the caller declares; the bytes decide the route.
    static func importDocument(
        data: Data,
        suggestedType: String,
        documentState: DocumentState,
        redactionState: RedactionState
    ) async {
        // Defensive precondition mirrors the URL-based
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
                returnPhase: returnPhase,
                documentState: docState,
                redactionState: redactState
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
        returnPhase: DocumentState.ReturnPhase,
        documentState: DocumentState,
        redactionState: RedactionState
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
                documentState: documentState,
                redactionState: redactionState
            )
        } catch is CancellationError { // LegalPhrases:safe (Swift keyword)
            // Cooperative cancellation surrenders silently —
            // `cancelActivePipeline` has already transitioned the phase to
            // `.empty`. Adding a failed-transition here would duplicate
            // the user-initiated cancel.
            return
        } catch let error as PipelineError { // LegalPhrases:safe (Swift keyword)
            // Defensive path: PDFKit may surface a typed error
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

    // MARK: - Validation and Loading

    /// Validate document data and load into state. Throws on validation failure.
    /// Old state is preserved until validation succeeds — clearing happens only
    /// after we confirm the new document is valid.
    /// PDF validation runs off MainActor via Task.detached to avoid blocking UI.
    private static func validateAndLoad(
        data: Data,
        documentState: DocumentState,
        redactionState: RedactionState
    ) async throws {
        // Size check — 50 MB practical limit based on memory budget
        let maxSize = 50 * 1024 * 1024
        guard data.count <= maxSize else {
            throw PipelineError.importError(.tooLarge(bytesRead: data.count))
        }

        // The bytes decide the route. Resecta opens PDF files only: an
        // image signature is refused before any decode; `%PDF` and unknown
        // payloads reach the PDF parser, which reports what it cannot open.
        guard detectPayloadKind(from: data) != .image else {
            throw PipelineError.importError(.unsupportedFormat)
        }

        // Offload all CPU-intensive PDF work off MainActor.
        // Cancellation propagates from the outer `activeImportTask`
        // via `withTaskCancellationHandler` to the detached task,
        // which observes it through the `Task.checkCancellation()`
        // calls in `validatePDFOffMainActor`.
        let detached = Task.detached {
            try await validatePDFOffMainActor(data: data)
        }
        let result = try await withTaskCancellationHandler {
            try await detached.value
        } onCancel: {
            detached.cancel()
        }

        // Re-check cancellation before mutating state — a cancel
        // signal arriving between the detached task's return and
        // this point should not produce a half-loaded document.
        try Task.checkCancellation()

        // Back on MainActor — apply validated results to state
        redactionState.clearForNewDocument()
        documentState.sourceDocument = result.document.document
        documentState.currentPageIndex = 0
        documentState.textLayerStatus = result.textLayerStatus
        documentState.sourceHasHiddenOCG = result.hasHiddenOCG
        documentState.sourceAnnotationFindings = result.annotationFindings
        documentState.sourceFilledFormFieldCount = result.filledFormFieldCount
        documentState.annotationNoticeDismissed = false
        documentState.lastUsedPipelineMode = nil
        documentState.wasPausedByBackground = false
        documentState.pausedFromPhase = nil  // clear alongside wasPausedByBackground
        documentState.transition(to: .editing)
    }

    // MARK: - Off-MainActor PDF Validation

    /// Perform all CPU-intensive PDF validation off MainActor.
    /// nonisolated: explicitly opted out of SE-0466 MainActor default to avoid blocking UI.
    /// async: the annotation walk below rides the engine's `@concurrent`
    /// `AnnotationAnalyzer.analyze`; every other stage is synchronous.
    private nonisolated static func validatePDFOffMainActor(data: Data) async throws -> PDFValidationResult {
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

        // Per-page dimension validation.
        // Per-iteration `Task.checkCancellation()` so a 500-page
        // document surrenders cooperatively when the outer
        // `activeImportTask` is cancelled by the Cancel button or the
        // scene-phase observer's `cancelActivePipeline` call.
        // Each iteration body runs inside `autoreleasepool`: PDFKit page
        // accessors queue autoreleased intermediates, and without a
        // per-page drain the cost of every page accumulates across the
        // whole loop instead of being released between pages.
        for i in 0..<doc.pageCount {
            try Task.checkCancellation()
            try autoreleasepool {
                guard let page = doc.page(at: i) else {
                    // Inaccessible pages in a valid PDF indicate corruption or
                    // malicious crafting — fail rather than silently skip.
                    throw PipelineError.importError(.corrupt)
                }
                let box = page.bounds(for: .cropBox)
                // CGRect auto-standardizes negative dimensions to positive.
                // PDFKit bounds(for:) always returns non-negative. Documented for awareness.
                guard box.width > 0, box.height > 0,
                      box.width <= 5000, box.height <= 5000 else {
                    throw PipelineError.importError(.invalidPageDimensions(pageIndex: i))
                }
            }
        }

        // Early rejection of PDFs with active content. Also checked in
        // verification Layer 4 on the output, but PDFKit parses the document
        // during import so we reject upfront to avoid loading malicious
        // payloads. The engine's walk covers the catalog-top keys and the
        // ISO-canonical carriers (/Names → /JavaScript, /OpenAction, page
        // /AA, annotation /A); the refusal carries its own case so the
        // failed screen names active content, not a damaged file.
        //
        // While we have a CGPDFDocument open, also walk
        // /OCProperties/D/OFF for hidden Optional Content Groups. The engine
        // cannot do this later because PDFDocument(data:) leaves
        // documentURL == nil; computing it here once threads through into
        // every PDFPageData via DocumentState.sourceHasHiddenOCG.
        var hasHiddenOCG = false
        if let provider = CGDataProvider(data: data as CFData),
           let cgDoc = CGPDFDocument(provider) {
            if let location = ActiveContentScan.firstLocation(in: cgDoc) {
                throw PipelineError.importError(.activeContent(location: location))
            }
            hasHiddenOCG = TextLayerExtractor.documentHasHiddenOCG(cgDoc)
        }

        // Detect text layers per page — can be slow for complex PDFs,
        // which is why this runs off MainActor.
        // Per-iteration `Task.checkCancellation()` mirrors the
        // dimension-validation loop above; both contribute to the
        // worst-case surrender latency on a multi-hundred-page document.
        // `autoreleasepool` per iteration for the same reason as the
        // dimension loop — `detectTextLayer` reads `page.string`, whose
        // autoreleased text machinery would otherwise accumulate across
        // every page of the document before draining.
        var textLayerStatus: [Int: TextLayerStatus] = [:]
        for i in 0..<doc.pageCount {
            try Task.checkCancellation()
            autoreleasepool {
                guard let page = doc.page(at: i) else { return }
                textLayerStatus[i] = TextLayerDetector.detectTextLayer(page)
            }
        }

        // Walk source annotations through the engine's analyzer (skips
        // Widget/form annotations by design), then count the form fields
        // that carry a value. The on-screen PDFKit view draws annotations
        // and field values; the export raster is built from the page
        // content stream, which includes neither — both results feed the
        // import notice banner so the user hears that mechanism before
        // exporting.
        let annotationResult = await AnnotationAnalyzer().analyze(document: doc)
        let filledFormFieldCount = ImportAnnotationNoticeBanner.filledFormFieldCount(in: doc)

        return PDFValidationResult(
            document: SendablePDFDocument(doc),
            textLayerStatus: textLayerStatus,
            hasHiddenOCG: hasHiddenOCG,
            annotationFindings: annotationResult.findings,
            filledFormFieldCount: filledFormFieldCount
        )
    }

    // MARK: - Sample Document Loading

    /// Load a bundled sample document. Single SampleDocument.pdf in Resources/.
    static func loadSampleDocument(
        named name: String = "SampleDocument",
        documentState: DocumentState,
        redactionState: RedactionState
    ) async {
        // v1.0 ships one sample document — no subdirectory needed.
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
