import Foundation

// See ARCH §4.1 for PipelineError definition.
// See ARCH §1.3 for mechanism-description language rules.

/// Error type for pipeline failures. Used as the associated value in
/// DocumentState.Phase.failed(error:returnPhase:).
///
/// Each case corresponds to a pipeline stage and carries only non-sensitive
/// metadata (page indices, step names). Document content, file names, and
/// paths are NEVER included in error values (ARCH §12.2).
public enum PipelineError: Sendable, LocalizedError {
    case importError(ImportFailure)
    case detectionError(DetectionFailure)
    case redactionError(RedactionFailure)
    case verificationError(VerificationFailure)
    case exportError(ExportFailure)

    // MARK: - Per-stage failure types

    public enum ImportFailure: Sendable {
        case corrupt
        case passwordProtected
        case tooLarge(bytesRead: Int)
        case unsupportedFormat
        case invalidPageDimensions(pageIndex: Int)
    }

    public enum DetectionFailure: Sendable {
        case ocrUnavailable
        case timeout(pageIndex: Int)
        case visionError(pageIndex: Int)
        // SEC-6 — Signed gazetteer manifest verification failed. The bundled
        // `gazetteer_manifest.json` did not match its Ed25519 signature, the
        // signature file is missing, the public key is malformed, or the
        // verification primitive rejected the signature. Engine degrades to
        // manual-redaction-only for the session (SEC-7 banner / toast).
        case detectionCorpusInvalid
    }

    public enum RedactionFailure: Sendable {
        case insufficientMemory(pageIndex: Int)
        case bitmapCreationFailed(pageIndex: Int)
        case fillVerificationFailed(pageIndex: Int)
        case renderTimeout(pageIndex: Int)
        // L-19: Pre-flight reject before CGContextDrawPDFPage, which is a
        // synchronous C call with no cancellation points (§2.7).
        case pageTooLarge(pageIndex: Int)
        case reconstructionFailed
    }

    public enum VerificationFailure: Sendable {
        case engineCrash(layerIndex: Int)
    }

    public enum ExportFailure: Sendable {
        case diskFull
        case writeFailed
        case filePurged  // IE-1-1: Output file purged by iOS while app was backgrounded
    }

    // MARK: - LocalizedError (mechanism-description language per ARCH §1.3)

    public var errorDescription: String? {
        switch self {
        case .importError(let f):
            switch f {
            case .corrupt: "This document could not be opened. The file may be damaged."
            case .passwordProtected: "This document is password-protected. Resecta does not support encrypted PDFs."
            case .tooLarge: "This document is too large to process on this device."
            case .unsupportedFormat: "This file format is not supported. Resecta works with PDF and image files."
            case .invalidPageDimensions(let p): "Page \(p + 1) has unsupported dimensions and cannot be processed."
            }
        case .detectionError(let f):
            switch f {
            case .ocrUnavailable: "Text recognition is not available on this device."
            case .timeout(let p): "Page \(p + 1) took too long to process and was skipped."
            case .visionError(let p): "Text recognition could not process page \(p + 1)."
            // SEC-6 — mechanism-description language per ARCH §1.3 / I6.
            case .detectionCorpusInvalid: "Auto-detection is unavailable because the detection corpus failed signature verification. Manual redaction tools remain available."
            }
        case .redactionError(let f):
            switch f {
            // Broadened to cover
            // both refusal paths now that `validatePage` wires into the
            // `.insufficientMemory` throw — an oversized page (>5,000 pt per
            // side) and a genuine memory shortfall both surface here.
            // Mechanism-description copy — no outcome-promise language.
            case .insufficientMemory: "This page could not be processed. Pages up to 5,000 points (about 69 inches) per side are supported; for memory-related failures, reducing output quality in Settings may help."
            case .bitmapCreationFailed(let p): "Could not create image buffer for page \(p + 1)."
            case .fillVerificationFailed(let p): "Redaction fill verification failed for page \(p + 1). The page may not be fully redacted."
            case .renderTimeout(let p): "Page \(p + 1) could not be rendered within the time limit."
            case .pageTooLarge(let p): "Page \(p + 1) has dimensions that exceed the safe rendering limit."
            case .reconstructionFailed: "The redacted document could not be assembled."
            }
        case .verificationError: "Verification could not be completed."
        case .exportError(let f):
            switch f {
            case .diskFull: "Not enough storage to save the document."
            case .writeFailed: "Could not save the document."
            case .filePurged: "The redacted document was removed by the system. Please re-run the redaction pipeline."
            }
        }
    }

    /// The page index relevant to this error, if applicable.
    public var pageIndex: Int? {
        switch self {
        case .detectionError(.timeout(let p)), .detectionError(.visionError(let p)),
             .redactionError(.insufficientMemory(let p)),
             .redactionError(.bitmapCreationFailed(let p)),
             .redactionError(.fillVerificationFailed(let p)),
             .redactionError(.renderTimeout(let p)),
             .redactionError(.pageTooLarge(let p)),
             .importError(.invalidPageDimensions(let p)):
            return p
        default:
            return nil
        }
    }

    /// Whether the user can retry after dismissing the error.
    public var isRecoverable: Bool {
        switch self {
        case .importError: false
        case .detectionError: true
        case .redactionError: true
        case .verificationError: true
        case .exportError(.diskFull): false
        case .exportError(.writeFailed): true
        case .exportError(.filePurged): true
        }
    }
}
