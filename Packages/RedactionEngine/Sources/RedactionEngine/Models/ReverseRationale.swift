import Foundation

// MARK: - Reverse Rationale / Coverage Report

/// Evaluation summary for a single snippet across every detector
/// category. Produced by `PIIDetector.reverseRationale(for:fullContext:...)`
/// and shown in the "Why this match?" popover.
///
/// Scope contract: the snippet is scored against a bounded context buffer
/// (≤500 chars), so cross-page positive/negative context and N-gram
/// neighbors outside the window are absent. The popover footer surfaces
/// this contract so users don't conflate the result with full-document
/// scoring.
public struct ReverseRationale: Sendable, Equatable {
    public let snippet: String
    let contextRange: NSRange
    public let considered: [ConsiderationResult]
    let doctypeGatedOut: [PIICategory]

    public init(
        snippet: String,
        contextRange: NSRange,
        considered: [ConsiderationResult],
        doctypeGatedOut: [PIICategory]
    ) {
        self.snippet = snippet
        self.contextRange = contextRange
        self.considered = considered
        self.doctypeGatedOut = doctypeGatedOut
    }
}

/// Per-category evaluation. Populated for every `PIICategory` even
/// when the detector does not run (doctypeGated / snippetNotInContext) so
/// the UI can render a stable row list.
public struct ConsiderationResult: Sendable, Equatable {
    public let category: PIICategory
    public let ruleID: String
    public let matched: Bool
    public let finalScore: Double?
    public let threshold: Double?
    public let reason: Reason
    /// Winner category when `reason == .suppressedByOverlap`. Always nil
    /// here — the overlap resolver populates this field only during live detection.
    public let overlapWinner: PIICategory?

    public init(
        category: PIICategory,
        ruleID: String,
        matched: Bool,
        finalScore: Double?,
        threshold: Double?,
        reason: Reason,
        overlapWinner: PIICategory? = nil
    ) {
        self.category = category
        self.ruleID = ruleID
        self.matched = matched
        self.finalScore = finalScore
        self.threshold = threshold
        self.reason = reason
        self.overlapWinner = overlapWinner
    }

    public enum Reason: String, Sendable, Equatable, Codable {
        case noMatch = "no-match"
        case belowThreshold = "below-threshold"
        case aboveThreshold = "above-threshold"
        case doctypeGated = "doctype-gated"
        case suppressedByUserTerm = "suppressed-by-user-term"
        case matchedAlwaysFlag = "matched-always-flag"
        case suppressedByOverlap = "suppressed-by-overlap"
        case snippetNotInContext = "snippet-not-in-context"
    }
}
