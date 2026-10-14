import Foundation
import CoreGraphics
import PDFKit
import RedactionEngine

// The import seam. A loader turns the bytes a door handed in into a parsed
// document plus the facts the editor records about it, or throws from the
// existing import-failure taxonomy. Nothing here reads app state or SwiftUI,
// so a loader runs off the main actor and a test drives it with no state
// object in scope. The wrapper (`ImportService`) applies the facts to the
// editor's state in one place.

/// Where a payload entered the app.
enum ImportDoor: Sendable, Equatable {
    /// The Files picker on Home: a security-scoped URL.
    case files
    /// The workspace's drag-and-drop target.
    case drop
    /// The bundled sample document.
    case sample
}

/// What a door hands a loader. The type a caller declares is recorded with
/// the bytes and never consulted: the router reads the bytes.
enum ImportPayload: Sendable {
    case bytes(Data, declaredType: String?, door: ImportDoor)

    /// The bytes to parse.
    var data: Data {
        switch self {
        case .bytes(let data, _, _): return data
        }
    }

    /// The door the payload came through.
    var door: ImportDoor {
        switch self {
        case .bytes(_, _, let door): return door
        }
    }

    /// The type the caller declared, if any: a record, not a routing input.
    var declaredType: String? {
        switch self {
        case .bytes(_, let declaredType, _): return declaredType
        }
    }
}

/// The caps a loader enforces. Production passes `.standard`; a test may
/// pass smaller ones to reach a cap with a small fixture.
struct ImportLimits: Sendable, Equatable {
    /// The largest payload admitted, in bytes.
    var maxBytes: Int = 50 * 1024 * 1024
    /// The largest page count admitted.
    var maxPages: Int = 500
    /// The largest crop-box side admitted, in PDF points.
    var maxPagePoints: CGFloat = 5_000

    /// The production caps.
    static let standard = ImportLimits()
}

/// What a loader learned about a document. The wrapper applies the whole
/// record to the editor's state through one function.
struct ImportFacts: Sendable {
    /// What the pages were parsed from.
    enum Origin: Sendable, Equatable {
        case pdf
    }

    let origin: Origin
    /// Per-page text-layer status, keyed by page index.
    let textLayerStatus: [Int: TextLayerStatus]
    /// Doc-level OCG hidden-layer presence, walked from the CGPDFDocument
    /// built off the raw bytes (PDFDocument(data:) does not retain a
    /// documentURL). Drives `TextLayerExtractor.pageReferencesHiddenOCG`.
    let hasHiddenOCG: Bool
    /// Non-Widget source annotations, one entry per subtype, from the
    /// engine's `AnnotationAnalyzer`. Drives the import notice banner:
    /// annotations are drawn by the on-screen PDFKit view but are not
    /// part of the page content stream the export raster is built from,
    /// so their presence is surfaced to the user at import.
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
struct LoadedDocument: Sendable {
    let document: SendablePDFDocument
    let facts: ImportFacts
}

/// A loader for one kind of payload.
protocol DocumentLoader: Sendable {
    /// Parse the payload and gather its facts. Throws
    /// `PipelineError.importError(_)` from the existing cases; cancellable
    /// through `Task.checkCancellation()` at every stage.
    func load(_ payload: ImportPayload, limits: ImportLimits) async throws -> LoadedDocument
}

/// What an import attempt came to.
enum ImportOutcome: Sendable, Equatable {
    /// The document is open for editing.
    case completed
    /// Nothing was loaded: the phase gate refused the attempt, the loader
    /// threw, or the attempt was cancelled.
    case refused
}
