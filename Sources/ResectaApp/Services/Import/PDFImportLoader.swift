import Foundation
import PDFKit
import CoreGraphics
import RedactionEngine

/// The PDF loader: the validation stages run in order, off the main actor,
/// against the bytes alone.
struct PDFImportLoader: DocumentLoader {
    func load(_ payload: ImportPayload, limits: ImportLimits) async throws -> LoadedDocument {
        try await ImportService.validatePDFOffMainActor(data: payload.data, limits: limits)
    }
}

extension ImportService {

    // MARK: - Off-MainActor PDF Validation

    /// Perform all CPU-intensive PDF validation off MainActor.
    /// nonisolated: explicitly opted out of SE-0466 MainActor default to avoid blocking UI.
    /// async: the annotation walk below rides the engine's `@concurrent`
    /// `AnnotationAnalyzer.analyze`; every other stage is synchronous.
    /// `PDFImportLoader` forwards here; the hub comments that cite this
    /// qualified name keep pointing at the stages.
    nonisolated static func validatePDFOffMainActor(
        data: Data,
        limits: ImportLimits = .standard
    ) async throws -> LoadedDocument {
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
        // the byte limit, causing excessive memory and processing time.
        guard doc.pageCount <= limits.maxPages else {
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
                      box.width <= limits.maxPagePoints, box.height <= limits.maxPagePoints else {
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

        // The encryption record. An owner-password-only file opens with no
        // prompt and still reads encrypted; a withheld permission marks the
        // restrictions. Nothing refuses on these — they are facts.
        let wasEncrypted = doc.isEncrypted
        let hadRestrictions = wasEncrypted
            && doc.permissionsStatus != .owner
            && !(doc.allowsCopying && doc.allowsPrinting && doc.allowsDocumentChanges
                 && doc.allowsDocumentAssembly && doc.allowsCommenting
                 && doc.allowsFormFieldEntry && doc.allowsContentAccessibility)

        let facts = ImportFacts(
            origin: .pdf,
            textLayerStatus: textLayerStatus,
            hasHiddenOCG: hasHiddenOCG,
            annotationFindings: annotationResult.findings,
            filledFormFieldCount: filledFormFieldCount,
            wasEncrypted: wasEncrypted,
            hadRestrictions: hadRestrictions
        )
        return LoadedDocument(document: SendablePDFDocument(doc), facts: facts)
    }
}
