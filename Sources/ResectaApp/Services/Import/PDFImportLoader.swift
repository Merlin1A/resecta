import Foundation
import PDFKit
import CoreGraphics
import RedactionEngine

/// The PDF loader: the validation stages run in order, off the main actor,
/// against the bytes alone.
nonisolated struct PDFImportLoader: DocumentLoader {
    func load(_ payload: ImportPayload, password: String?, limits: ImportLimits) async throws -> LoadedDocument {
        try await ImportService.validatePDFOffMainActor(data: payload.data, password: password, limits: limits)
    }
}

extension ImportService {

    // MARK: - Off-MainActor PDF Validation

    /// Perform all CPU-intensive PDF validation off MainActor.
    /// nonisolated: explicitly opted out of SE-0466 MainActor default to avoid blocking UI.
    /// async: the annotation walk below rides the engine's `@concurrent`
    /// `AnnotationAnalyzer.analyze`; every other stage is synchronous.
    /// `PDFImportLoader` forwards here; the hub comments that cite this
    /// qualified name keep pointing at the stages. `password` is the one
    /// the user typed for a locked document; nil on a first attempt.
    nonisolated static func validatePDFOffMainActor(
        data: Data,
        password: String? = nil,
        limits: ImportLimits = .standard
    ) async throws -> LoadedDocument {
        guard let doc = PDFDocument(data: data) else {
            throw PipelineError.importError(.corrupt)
        }
        // The lock gate. A locked document with no password is refused so
        // the wrapper can ask for one; a password that does not unlock it is
        // refused the same way so the sheet asks again. Every stage below
        // reads the unlocked document.
        if doc.isLocked {
            guard let password else {
                throw PipelineError.importError(.passwordProtected)
            }
            guard doc.unlock(withPassword: password) else {
                throw PipelineError.importError(.passwordProtected)
            }
        }
        // The encryption record, read before any page. An owner-password-only
        // file opens with no prompt and still reads encrypted; a withheld
        // permission marks the restrictions. Nothing refuses on these — they
        // are facts.
        let wasEncrypted = doc.isEncrypted
        let hadRestrictions = wasEncrypted
            && doc.permissionsStatus != .owner
            && !(doc.allowsCopying && doc.allowsPrinting && doc.allowsDocumentChanges
                 && doc.allowsDocumentAssembly && doc.allowsCommenting
                 && doc.allowsFormFieldEntry && doc.allowsContentAccessibility)

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

        // The geometry stage, on the unlocked document: a page whose
        // dictionary cannot be read is refused as damaged (the render's
        // `/UserUnit` and `/Rotate` arms would skip it), and a page the
        // render would refuse — a side under 10 pt, a non-default
        // `/UserUnit`, a `/Rotate` PDFKit and CoreGraphics read apart — is
        // refused here with the error the render raises.
        for i in 0..<doc.pageCount {
            try Task.checkCancellation()
            try autoreleasepool {
                guard let page = doc.page(at: i), let pageRef = page.pageRef,
                      pageRef.dictionary != nil else {
                    throw PipelineError.importError(.corrupt)
                }
                guard validatePageGeometry(page) else {
                    throw PipelineError.redactionError(.unsupportedPageGeometry(pageIndex: i))
                }
            }
        }

        // The walk reader: the parser's own view of the document — unlocked
        // with the same password PDFKit took — which the active-content and
        // hidden-layer walks inspect (stage by stage in `inspectWalkReader`).
        let hasHiddenOCG = try inspectWalkReader(doc.documentRef, expectedPageCount: doc.pageCount)

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

    // MARK: - The walk reader

    /// The reader the active-content walk and the hidden-layer walk inspect:
    /// the Core Graphics document behind the parsed PDFKit document
    /// (`PDFDocument.documentRef`), so one parse and one unlock serve every
    /// stage. A pure function of the reader so the stage can be driven by a
    /// test on its own.
    ///
    /// Active content is refused with its own case so the failed screen names
    /// it, not a damaged file. The hidden-layer fact (`/OCProperties → /D →
    /// /OFF`) is read here, once, because `PDFDocument(data:)` leaves
    /// `documentURL` nil and the engine cannot walk it later; it threads into
    /// every `PDFPageData` through `DocumentState.sourceHasHiddenOCG`.
    /// `expectedPageCount` is PDFKit's page count for the same bytes.
    ///
    /// The reader must exist, be unlocked, read a catalog and agree with
    /// PDFKit on the page count, and the walk must read every page and every
    /// action chain to its bound; otherwise the walks would answer "clean"
    /// for what they could not see, so the document is refused as one the
    /// app cannot read. An owner-password-only file opens with no prompt in
    /// PDFKit; CoreGraphics may report it locked until the empty user
    /// password is tried, so that is tried first.
    nonisolated static func inspectWalkReader(_ reader: CGPDFDocument?, expectedPageCount: Int) throws -> Bool {
        guard let cgDoc = reader else {
            throw PipelineError.importError(.corrupt)
        }
        if !cgDoc.isUnlocked {
            _ = cgDoc.unlockWithPassword("")
        }
        guard cgDoc.isUnlocked, cgDoc.catalog != nil,
              cgDoc.numberOfPages == expectedPageCount else {
            throw PipelineError.importError(.corrupt)
        }
        if let location = ActiveContentScan.firstLocation(in: cgDoc) {
            if case .couldNotScan = location {
                throw PipelineError.importError(.corrupt)
            }
            throw PipelineError.importError(.activeContent(location: location))
        }
        return TextLayerExtractor.documentHasHiddenOCG(cgDoc)
    }
}
