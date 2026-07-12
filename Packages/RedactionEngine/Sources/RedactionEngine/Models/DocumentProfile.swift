import Foundation

// Document profile classification for AnnotationAnalyzer.
// Conservative heuristic — default to .unredacted when uncertain (OQ-4).

/// Classification of a PDF document's redaction state based on annotation analysis.
public enum DocumentProfile: Sendable {
    /// No redaction-like annotations detected.
    case unredacted
    /// Redaction annotations or black-filled square annotations detected.
    case redacted(markCount: Int)
}
