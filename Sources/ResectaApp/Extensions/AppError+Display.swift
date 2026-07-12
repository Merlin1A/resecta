import Foundation
import SwiftUI
import RedactionEngine

// §A4h, §A9: Provides localizedTitle and localizedRecovery for FailedStateView.
// All copy uses mechanism-description language per ARCH §1.3.

extension PipelineError {

    /// Short headline for FailedStateView (1 line).
    var localizedTitle: String {
        switch self {
        case .importError(let f):
            switch f {
            case .corrupt:
                "Document Could Not Be Opened"
            case .passwordProtected:
                "Password-Protected Document"
            case .tooLarge:
                "Document Too Large"
            case .unsupportedFormat:
                "Unsupported File Format"
            case .invalidPageDimensions:
                "Invalid Page Dimensions"
            }

        case .detectionError(let f):
            switch f {
            case .ocrUnavailable:
                "Text Recognition Unavailable"
            case .timeout:
                "Detection Timed Out"
            case .visionError:
                "Detection Could Not Complete"
            // SEC-6 — mechanism-description per ARCH §1.3 / I6.
            case .detectionCorpusInvalid:
                "Detection Corpus Verification Failed"
            }

        case .redactionError(let f):
            switch f {
            case .insufficientMemory:
                "Not Enough Memory"
            case .bitmapCreationFailed:
                "Image Buffer Error"
            case .fillVerificationFailed:
                "Redaction Verification Failed"
            case .renderTimeout:
                "Rendering Timed Out"
            case .pageTooLarge:
                "Page Dimensions Exceeded"
            case .reconstructionFailed:
                "Document Assembly Failed"
            }

        case .verificationError:
            "Verification Could Not Complete"

        case .exportError(let f):
            switch f {
            case .diskFull:
                "Not Enough Storage"
            case .writeFailed:
                "Could Not Save Document"
            case .filePurged:
                // KI-4: iOS reclaimed temp file while backgrounded
                "Document No Longer Available"
            }
        }
    }

    /// Multi-line recovery description for FailedStateView body.
    var localizedRecovery: String {
        switch self {
        case .importError(let f):
            switch f {
            case .corrupt:
                // Q-UX-import-iofailure-mislabel (Pkg N): broadened copy
                // covers the read-failure family — damaged file, file
                // locked by another app, temporary I/O unavailability.
                // Mechanism-description compliant: names what the engine
                // observed (could-not-read), enumerates the common
                // mechanisms without promising a root cause. V1.0-safe
                // path; granular .ioError(reason:) case slot V1.1+
                // (HARD-STOP per CLAUDE.md — PipelineError hierarchy is
                // unchanged in this package).
                "The file could not be read. It may be damaged, locked by another app, or temporarily unavailable."
            case .passwordProtected:
                "Resecta does not support encrypted PDFs. Remove the password in another app, then import the file."
            case .tooLarge(let bytes):
                "This file is approximately \(bytes / (1024 * 1024)) MB. Try a smaller document or reduce the page count."
            case .unsupportedFormat:
                "Resecta works with PDF and image files (JPEG, PNG, HEIC). Other formats are not supported."
            case .invalidPageDimensions(let p):
                "Page \(p + 1) has dimensions outside the supported range. Each page must be between 1 and 5,000 points."
            }

        case .detectionError(let f):
            switch f {
            case .ocrUnavailable:
                "The on-device text recognition system is not available. You can still draw redaction regions manually."
            case .timeout(let p):
                "Page \(p + 1) took longer than expected to process. You can try again or draw regions manually."
            case .visionError(let p):
                "Text recognition encountered an issue on page \(p + 1). You can try again or draw regions manually."
            // SEC-6 — mechanism description, I6 vocabulary. Tells the user
            // what the engine did (signature check failed → corpus not
            // loaded → manual tools remain).
            case .detectionCorpusInvalid:
                "The detection corpus did not pass signature verification, so auto-detection is unavailable for this session. Manual redaction tools remain available."
            }

        case .redactionError(let f):
            switch f {
            case .insufficientMemory(let p):
                "Page \(p + 1) could not be processed due to available memory. Try reducing output quality in Settings, or close other apps and try again."
            case .bitmapCreationFailed(let p):
                "An image buffer could not be created for page \(p + 1). Try reducing output quality in Settings."
            case .fillVerificationFailed(let p):
                "Redaction fill verification did not pass for page \(p + 1). The redaction may not be complete. Try again or reduce output quality in Settings."
            case .renderTimeout(let p):
                "Page \(p + 1) could not be rendered within the time limit. Try reducing output quality in Settings."
            case .pageTooLarge(let p):
                "Page \(p + 1) has dimensions that exceed the safe rendering limit. This may indicate a non-standard or damaged PDF."
            case .reconstructionFailed:
                "The redacted document could not be assembled. Your redaction regions are preserved — you can try again."
            }

        case .verificationError(.engineCrash(let layer)):
            "The verification process encountered an issue at layer \(layer + 1). The redacted document may still be valid — you can export it without verification or try again."

        case .exportError(let f):
            switch f {
            case .diskFull:
                "There is not enough free storage on this device to save the document. Free up space and try again."
            case .writeFailed:
                "The document could not be written to storage. Try again, or check available storage."
            case .filePurged:
                // KI-4: §A4h specific copy
                "The temporary working copy is no longer accessible. iOS is designed to periodically reclaim temporary storage."
            }
        }
    }

    /// SF Symbol name appropriate for the error severity.
    var severitySymbol: String {
        switch self {
        case .detectionError(.timeout), .detectionError(.ocrUnavailable):
            "exclamationmark.triangle.fill"  // Warning-level (recoverable, non-critical)
        default:
            "xmark.circle.fill"  // Error-level
        }
    }

    /// Color for the severity symbol (typed `Color`,
    /// replacing the stringly "orange"/"red" + string-compare at the call
    /// site; AA text-tier shades since the symbol renders beside text copy).
    var severityColor: Color {
        switch self {
        case .detectionError(.timeout), .detectionError(.ocrUnavailable):
            ResectaTokens.SemanticColor.warnText
        default:
            ResectaTokens.SemanticColor.failText
        }
    }
}
