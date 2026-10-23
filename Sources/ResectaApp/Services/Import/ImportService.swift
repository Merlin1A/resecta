import Foundation
import PDFKit
import UniformTypeIdentifiers
import RedactionEngine

// The import wrapper: the phase transitions around a load. A door hands the
// bytes in; the router picks the loader; the loader runs off the main actor;
// the facts it returns are applied to the editor's state in one place. The
// seam itself lives beside this file: `DocumentLoader.swift` (the types and
// the protocol), `ImportRouter.swift` (the bytes decide), and
// `PDFImportLoader.swift` (the PDF stages).

enum ImportService {

    // MARK: - The accepted types

    /// The image types the loader decodes, as the Files picker and the
    /// Photos door read them. Never the generic image type: that would
    /// admit every codec Image I/O carries.
    static let acceptedImageTypes: [UTType] = [.jpeg, .png, .heic, .heif]
    /// What the Files picker offers: PDF and the image types above.
    static let acceptedContentTypes: [UTType] = [.pdf] + acceptedImageTypes

    // MARK: - Import from Security-Scoped URL (the Files door)

    /// Full import flow from a security-scoped URL.
    /// Transitions: current → .importing → .editing (success) or .failed (error).
    /// Old document state is preserved until validation succeeds.
    /// Async: file I/O runs off MainActor to avoid blocking UI.
    /// The work is wrapped in a stored Task so the Cancel affordance and
    /// scene-phase observer can reach the detached per-page loops via
    /// `documentState.activeImportTask`.
    @discardableResult
    static func importDocument(
        from url: URL,
        documentState: DocumentState,
        redactionState: RedactionState
    ) async -> ImportOutcome {
        // Defensive precondition. The transition table
        // is the canonical authority for "may we enter `.importing` now".
        // If the entry-point view-layer gate was bypassed (programmatic
        // call, race against a pipeline start), refuse to mutate
        // `redactionState.clearForNewDocument()` and
        // `documentState.sourceDocument` before this import knows it
        // owns the slot.
        guard documentState.canStartImport else { return .refused }

        guard url.startAccessingSecurityScopedResource() else {
            documentState.transition(to: .importing)
            documentState.transition(to: .failed(
                error: .importError(.corrupt),
                returnPhase: .empty
            ))
            return .refused
        }
        defer { url.stopAccessingSecurityScopedResource() }

        let returnPhase: DocumentState.ReturnPhase =
            documentState.phaseKind == .editing ? .editing : .empty

        guard documentState.transition(to: .importing) else { return .refused }

        // Registers a child Task on `activeImportTask` so
        // `cancelActivePipeline` reaches the detached per-page loops via
        // the `Task.checkCancellation()` calls in `validatePDFOffMainActor`.
        // `withTaskCancellationHandler` propagates the caller's cancellation
        // signal (e.g., the scene-phase observer's call) to `workTask`.
        //
        // nonisolated(unsafe): @Observable prevents Sendable; Task captures
        // the references implicitly. Safe because all access is on MainActor
        // (mirrors the `PipelineCoordinator` Task-dispatch pattern).
        let declaredType = url.pathExtension
        nonisolated(unsafe) let docState = documentState
        nonisolated(unsafe) let redactState = redactionState
        let outcome = ImportOutcomeBox()
        let workTask = Task<Void, Never> { @MainActor in
            outcome.value = await runImport(
                source: .file(url, declaredType: declaredType),
                password: nil,
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
        return outcome.value
    }

    // MARK: - Import from Raw Data (the drop door, the sample)

    /// Full import flow from in-memory data.
    /// Async for consistency with URL-based import; validation runs on MainActor.
    /// Same Task-registration pattern as the URL variant. `suggestedType` is
    /// the type the caller declares, recorded on the payload; the bytes
    /// decide the route. `password` is the one the sheet collected for a
    /// locked document; the password sheet re-runs a held import through
    /// this door with the bytes it kept.
    @discardableResult
    static func importDocument(
        data: Data,
        suggestedType: String? = nil,
        door: ImportDoor = .drop,
        password: String? = nil,
        documentState: DocumentState,
        redactionState: RedactionState
    ) async -> ImportOutcome {
        // Defensive precondition mirrors the URL-based
        // overload above. See comment there for the rationale.
        guard documentState.canStartImport else { return .refused }

        let returnPhase: DocumentState.ReturnPhase =
            documentState.phaseKind == .editing ? .editing : .empty

        guard documentState.transition(to: .importing) else { return .refused }

        // nonisolated(unsafe): see comment in the URL variant above.
        nonisolated(unsafe) let docState = documentState
        nonisolated(unsafe) let redactState = redactionState
        let outcome = ImportOutcomeBox()
        let workTask = Task<Void, Never> { @MainActor in
            outcome.value = await runImport(
                source: .bytes(data, declaredType: suggestedType, door: door),
                password: password,
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
        return outcome.value
    }

    /// The outcome an import task hands back to its caller; the task stored
    /// on `activeImportTask` stays the one cancellation reaches.
    private final class ImportOutcomeBox {
        var value: ImportOutcome = .refused
    }

    // MARK: - Inner Work (Cancellation-aware)

    // MARK: - Import from the Photos picker

    /// The Photos door: `images` yields each picked image's bytes in pick
    /// order and `count` is how many were picked; the loader turns them
    /// into one page each. Transitions as the other doors do; a stream
    /// that throws refuses the whole import with the class it threw.
    @discardableResult
    static func importImages(
        _ images: AsyncThrowingStream<Data, any Error>,
        count: Int,
        door: ImportDoor = .photos,
        documentState: DocumentState,
        redactionState: RedactionState
    ) async -> ImportOutcome {
        guard documentState.canStartImport else { return .refused }

        let returnPhase: DocumentState.ReturnPhase =
            documentState.phaseKind == .editing ? .editing : .empty

        guard documentState.transition(to: .importing) else { return .refused }

        // nonisolated(unsafe): see comment in the URL variant above.
        nonisolated(unsafe) let docState = documentState
        nonisolated(unsafe) let redactState = redactionState
        let outcome = ImportOutcomeBox()
        let workTask = Task<Void, Never> { @MainActor in
            outcome.value = await runImport(
                source: .images(images, count: count, door: door),
                password: nil,
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
        return outcome.value
    }

    /// What a door handed in, before the bytes are read.
    private enum ImportSource {
        case bytes(Data, declaredType: String?, door: ImportDoor)
        case file(URL, declaredType: String)
        case images(AsyncThrowingStream<Data, any Error>, count: Int, door: ImportDoor)
    }

    /// Shared work body for both `importDocument` variants. Runs inside the
    /// task stored on `documentState.activeImportTask` so cancellation
    /// reaches the detached per-page validation loops. Old state is
    /// preserved until the loader returns — clearing happens only after the
    /// new document is known to be valid.
    @MainActor
    private static func runImport(
        source: ImportSource,
        password: String?,
        returnPhase: DocumentState.ReturnPhase,
        documentState: DocumentState,
        redactionState: RedactionState
    ) async -> ImportOutcome {
        let limits = ImportLimits.standard
        // The bytes a locked document is held by while the sheet asks for
        // its password; set once the payload exists, read when the loader throws.
        var heldPayload: ImportPayload?
        do {
            let payload: ImportPayload
            switch source {
            case .bytes(let data, let declaredType, let door):
                payload = .bytes(data, declaredType: declaredType, door: door)
            case .file(let url, let declaredType):
                // Offload file I/O to avoid blocking MainActor. Cancellation
                // is propagated to the detached read via `withTaskCancellationHandler`.
                let readTask = Task.detached { try readPayload(from: url, limits: limits) }
                let data = try await withTaskCancellationHandler {
                    try await readTask.value
                } onCancel: {
                    readTask.cancel()
                }
                payload = .bytes(data, declaredType: declaredType, door: .files)
            case .images(let stream, let count, let door):
                payload = .images(stream, count: count, door: door)
            }

            let loader: any DocumentLoader
            switch payload {
            case .bytes:
                // Size check — 50 MB practical limit based on memory budget
                guard payload.data.count <= limits.maxBytes else {
                    throw PipelineError.importError(.tooLarge(bytesRead: payload.data.count))
                }
                heldPayload = payload
                // The bytes decide the route: a PDF or an image loader, or
                // the unsupported-format refusal before any decode.
                loader = try ImportRouter.route(data: payload.data)
            case .images:
                // Each item's bytes are checked by the loader as they arrive.
                loader = ImageImportLoader()
            }

            // Offload all CPU-intensive parsing off MainActor.
            // Cancellation propagates from the outer `activeImportTask`
            // via `withTaskCancellationHandler` to the detached task,
            // which observes it through the loader's
            // `Task.checkCancellation()` calls.
            let detached = Task.detached {
                try await loader.load(payload, password: password, limits: limits)
            }
            let loaded = try await withTaskCancellationHandler {
                try await detached.value
            } onCancel: {
                detached.cancel()
            }

            // Re-check cancellation before mutating state — a cancel
            // signal arriving between the detached task's return and
            // this point should not produce a half-loaded document.
            try Task.checkCancellation()

            apply(loaded, password: password, documentState: documentState, redactionState: redactionState)
            return .completed
        } catch is CancellationError { // LegalPhrases:safe (Swift keyword)
            // Cooperative cancellation surrenders silently —
            // `cancelActivePipeline` has already transitioned the phase
            // (back to the open document, else to `.empty`) and leaves the
            // open document's password holder alone. Adding a
            // failed-transition here would duplicate the user-initiated
            // cancel.
            return .refused
        } catch let error as PipelineError { // LegalPhrases:safe (Swift keyword)
            // Defensive path: PDFKit may surface a typed error
            // on rare timing before the cancellation propagates back.
            guard documentState.phaseKind == .importing else { return .refused }
            documentState.transition(to: .failed(error: error, returnPhase: returnPhase))
            // A locked document is held with its bytes so the password sheet
            // can re-run the import; the phase beneath the sheet is the
            // failed state the refusal produced. Any other refusal of a
            // supplied password releases nothing: there is no hold.
            if case .importError(.passwordProtected) = error, let heldPayload {
                return .needsPassword(LockedImportHold(
                    bytes: heldPayload.data, declaredType: heldPayload.declaredType,
                    door: heldPayload.door, returnPhase: returnPhase))
            }
            return .refused
        } catch { // LegalPhrases:safe (Swift keyword)
            if error is CancellationError { return .refused }
            guard documentState.phaseKind == .importing else { return .refused }
            documentState.transition(to: .failed(
                error: .importError(.corrupt),
                returnPhase: returnPhase
            ))
            return .refused
        }
    }

    // MARK: - Reading a file

    /// Read a file's bytes for import. The size is checked from the file's
    /// attributes before any byte is read, so a file over the cap is
    /// refused unread; the read itself maps the file when the system allows
    /// it instead of copying it into memory.
    nonisolated static func readPayload(from url: URL, limits: ImportLimits = .standard) throws -> Data {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= limits.maxBytes else {
            throw PipelineError.importError(.tooLarge(bytesRead: size))
        }
        return try Data(contentsOf: url, options: .mappedIfSafe)
    }

    // MARK: - A refusal met at the door

    /// Record a refusal a door met before any bytes reached the import — a
    /// dropped file over the size cap. The phase takes the same
    /// `.importing → .failed` pair a failed load produces, so the failed
    /// screen names the refusal; an open document is kept.
    @MainActor
    /// The notice for a drop of more than one item. The drop door opens one
    /// document, the first; the rest are not read.
    static func dropOpenedFirstMessage(droppedCount: Int) -> String {
        "Only the first of the \(droppedCount) dropped files was opened. Drop the others one at a time."
    }

    static func refuse(_ failure: PipelineError.ImportFailure, documentState: DocumentState) {
        guard documentState.canStartImport else { return }
        let returnPhase: DocumentState.ReturnPhase =
            documentState.phaseKind == .editing ? .editing : .empty
        guard documentState.transition(to: .importing) else { return }
        documentState.transition(to: .failed(
            error: .importError(failure),
            returnPhase: returnPhase
        ))
    }

    // MARK: - The facts applier

    /// The one place a loader's facts reach the editor's state. Back on
    /// MainActor; the old document is replaced only here.
    @MainActor
    private static func apply(
        _ loaded: LoadedDocument,
        password: String?,
        documentState: DocumentState,
        redactionState: RedactionState
    ) {
        redactionState.clearForNewDocument()
        ThumbnailCache.clear()   // the previous document's page images never outlive it
        documentState.sourceDocument = loaded.document.document
        documentState.sourceFacts = loaded.facts.summary
        // The password that unlocked the source stays with the session: the
        // search copy is rebuilt from the document's bytes, which keep their
        // encryption, and opens with it (`SearchCopy`).
        if let password {
            documentState.documentPassword.set(password)
        } else {
            documentState.documentPassword.wipe()
        }
        documentState.currentPageIndex = 0
        documentState.textLayerStatus = loaded.facts.textLayerStatus
        documentState.sourceHasHiddenOCG = loaded.facts.hasHiddenOCG
        documentState.sourceAnnotationFindings = loaded.facts.annotationFindings
        documentState.sourceFilledFormFieldCount = loaded.facts.filledFormFieldCount
        documentState.annotationNoticeDismissed = false
        documentState.lastUsedPipelineMode = nil
        documentState.documentOverride = nil
        documentState.wasPausedByBackground = false
        documentState.pausedFromPhase = nil  // clear alongside wasPausedByBackground
        documentState.transition(to: .editing)
    }

    // MARK: - Sample Document Loading

    /// Load a bundled sample document. Single SampleDocument.pdf in Resources/.
    #if DEBUG
    /// A bundled synthetic image (UITestFixtures/, Debug only) through the
    /// image loader, for the `--loadTestImage` launch hook: the JPEG is
    /// tried first, then the HEIC. A missing fixture fails the import as
    /// damaged rather than silently opening nothing.
    static func loadTestImage(
        named name: String,
        documentState: DocumentState,
        redactionState: RedactionState
    ) async {
        let url = ["jpg", "heic"].lazy
            .compactMap { Bundle.main.url(forResource: name, withExtension: $0) }.first
        guard let url, let data = try? Data(contentsOf: url) else {
            assertionFailure("Test image '\(name)' not found in bundle")
            documentState.transition(to: .importing)
            documentState.transition(to: .failed(error: .importError(.corrupt), returnPhase: .empty))
            return
        }
        let stream = AsyncThrowingStream<Data, any Error> { continuation in
            continuation.yield(data)
            continuation.finish()
        }
        await importImages(stream, count: 1, documentState: documentState, redactionState: redactionState)
    }
    #endif

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
            data: data, suggestedType: "pdf", door: .sample,
            documentState: documentState, redactionState: redactionState
        )
    }
}
