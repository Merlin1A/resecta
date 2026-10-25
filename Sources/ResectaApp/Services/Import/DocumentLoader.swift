import Foundation
import CoreGraphics
import PDFKit
import RedactionEngine

// The import seam. A loader turns the bytes a door handed in into a parsed
// document plus the facts the editor records about it, or throws from the
// existing import-failure taxonomy. Nothing here reads app state or SwiftUI,
// so a loader runs off the main actor and a test drives it with no state
// object in scope. The wrapper (`ImportService`) applies the facts to the
// editor's state in one place. Every type here is `nonisolated`: the
// loaders run off the main actor and the values cross that boundary.

/// Where a payload entered the app.
nonisolated enum ImportDoor: Sendable, Equatable {
    /// The Files picker on Home: a security-scoped URL.
    case files
    /// The workspace's drag-and-drop target.
    /// The system Photos picker: one or more images, in the order picked.
    case photos
    case drop
    /// The bundled sample document.
    case sample
}

/// What a door hands a loader. The type a caller declares is recorded with
/// the bytes and never consulted: the router reads the bytes.
nonisolated enum ImportPayload: Sendable {
    case bytes(Data, declaredType: String?, door: ImportDoor)
    /// Photos: one image's bytes at a time, in pick order, from a stream
    /// that yields `count` items and throws when an item cannot be read.
    /// At most one input's bytes are resident while the loader works.
    case images(AsyncThrowingStream<Data, any Error>, count: Int, door: ImportDoor)

    /// The bytes to parse.
    var data: Data {
        switch self {
        case .bytes(let data, _, _): return data
        case .images: return Data()
        }
    }

    /// The door the payload came through.
    var door: ImportDoor {
        switch self {
        case .bytes(_, _, let door): return door
        case .images(_, _, let door): return door
        }
    }

    /// The type the caller declared, if any: a record, not a routing input.
    var declaredType: String? {
        switch self {
        case .bytes(_, let declaredType, _): return declaredType
        case .images: return nil
        }
    }
}

/// The caps a loader enforces. Production passes `.standard`; a test may
/// pass smaller ones to reach a cap with a small fixture.
nonisolated struct ImportLimits: Sendable, Equatable {
    /// The largest payload admitted, in bytes.
    var maxBytes: Int = 50 * 1024 * 1024
    /// The largest page count admitted.
    var maxPages: Int = 500
    /// The largest crop-box side admitted, in PDF points.
    var maxPagePoints: CGFloat = 5_000
    /// The most pixels an image is decoded to; a larger image is downsampled
    /// at decode so the page stays inside the OCR render caps.
    var maxDecodedImagePixels: Int = 25_000_000
    /// The longest side an imported image keeps, in pixels.
    var maxImageSide: Int = 8_000
    /// The largest pixel count an image may declare before any decode.
    var maxDeclaredImagePixels: Int = 100_000_000
    /// The shortest side an image must have, in pixels (the 10-pt geometry
    /// floor at 300 pixels per inch).
    var minImageSide: Int = 42
    /// The most images one Photos pick turns into pages.
    var maxImagesPerImport: Int = 20

    /// The production caps.
    static let standard = ImportLimits()
}

/// What a loader learned about a document. The wrapper applies the whole
/// record to the editor's state through one function.
nonisolated struct ImportFacts: Sendable {
    /// What the pages were parsed from.
    enum Origin: Sendable, Equatable {
        case pdf
        /// One page per imported image, drawn from the decoded pixels.
        case images(count: Int)
    }

    let origin: Origin
    /// Per-page text-layer status, keyed by page index.
    let textLayerStatus: [Int: TextLayerStatus]
    /// Doc-level OCG hidden-layer presence, walked from the CGPDFDocument
    /// built off the raw bytes (PDFDocument(data:) does not retain a
    /// documentURL). Drives `TextLayerExtractor.pageReferencesHiddenOCG`.
    let hasHiddenOCG: Bool
    /// Non-Widget source annotations, one entry per subtype, from the
    /// engine's `AnnotationAnalyzer`, plus one entry for form fields drawn
    /// as an opaque cover (`ImportAnnotationNoticeBanner.coverWidgetFindingID`)
    /// and one document-level entry
    /// (`ImportAnnotationNoticeBanner.formDataOrAttachmentsFindingID`) when
    /// the source carries XFA form data or an embedded file. Drives the
    /// import notice banner: annotations are drawn by the on-screen PDFKit
    /// view but are not part of the page content stream the export raster
    /// is built from, and the rebuilt output carries no form data packet
    /// and no attachment, so their presence is surfaced to the user at import.
    let annotationFindings: [PDFFinding]
    /// Widget annotations whose field carries a value, counted by
    /// `ImportAnnotationNoticeBanner.filledFormFieldCount(in:)`. The
    /// analyzer skips widgets; the viewer draws their values and the
    /// export raster does not carry them, so the count feeds the same
    /// import notice.
    let filledFormFieldCount: Int
    /// The source was encrypted. An owner-password-only file opens with no
    /// prompt and still reads true.
    let wasEncrypted: Bool
    /// The source was encrypted and its owner withheld at least one
    /// permission: copying, printing, changes, assembly, commenting, form
    /// entry or content accessibility.
    let hadRestrictions: Bool
    /// Pages with a text layer Search cannot read (garbled encoding, or glyphs
    /// with no geometry; `TextLayerDetector.unreadableForSearch`): Search reads
    /// them by OCR. Export and verification keep `textLayerStatus`.
    var searchUnreadablePages: Set<Int> = []

    /// The part of the record the editor keeps for the session.
    struct Summary: Sendable, Equatable {
        var origin: Origin = .pdf
        var wasEncrypted = false
        var hadRestrictions = false
    }

    var summary: Summary {
        Summary(origin: origin, wasEncrypted: wasEncrypted, hadRestrictions: hadRestrictions)
    }
}

/// A parsed document with its facts, handed across the isolation boundary.
/// The PDFDocument is wrapped because PDFDocument is not Sendable.
nonisolated struct LoadedDocument: Sendable {
    let document: SendablePDFDocument
    let facts: ImportFacts
}

/// A loader for one kind of payload.
nonisolated protocol DocumentLoader: Sendable {
    /// Parse the payload and gather its facts. Throws
    /// `PipelineError.importError(_)` from the existing cases; cancellable
    /// through `Task.checkCancellation()` at every stage. `password` is the
    /// one the user typed for a locked document, nil on a first attempt.
    func load(_ payload: ImportPayload, password: String?, limits: ImportLimits) async throws -> LoadedDocument
}

/// A locked document the import is holding while the password sheet is up:
/// the payload's bytes (the Files scope has ended and a dropped file belongs
/// to the system, so a re-read is not possible), where the phase returns on
/// Cancel, and the attempts so far. Released on every exit but a wrong
/// password.
nonisolated struct LockedImportHold: Sendable, Identifiable, Equatable {
    /// How the last attempt ended.
    enum Outcome: Sendable, Equatable {
        /// No password has been tried.
        case awaiting
        /// The password did not unlock the document; the sheet asks again.
        case wrongPassword
        /// The password unlocked the document, but it could not be read in
        /// full: the terminal line.
        case cannotOpen
    }

    let id = UUID()
    let bytes: Data
    let declaredType: String?
    let door: ImportDoor
    let returnPhase: DocumentState.ReturnPhase
    var attempts: Int = 0
    var lastOutcome: Outcome = .awaiting

    init(bytes: Data, declaredType: String?, door: ImportDoor, returnPhase: DocumentState.ReturnPhase) {
        self.bytes = bytes
        self.declaredType = declaredType
        self.door = door
        self.returnPhase = returnPhase
    }

    static func == (lhs: LockedImportHold, rhs: LockedImportHold) -> Bool { lhs.id == rhs.id }
}

/// What an import attempt came to.
nonisolated enum ImportOutcome: Sendable, Equatable {
    /// The document is open for editing.
    case completed
    /// Nothing was loaded: the phase gate refused the attempt, the loader
    /// threw, or the attempt was cancelled.
    case refused
    /// The document needs a password that was not supplied, or the supplied
    /// one did not unlock it; the hold carries the bytes for the next attempt.
    case needsPassword(LockedImportHold)
}
