import Foundation

// Pkg G.3 — multi-term TextField submission validation.
//
// TRUST-multiterm-no-length-cap: the multi-term TextField previously
// accepted arbitrary-length input that bypassed
// `DocumentSearcher.maxRegexPatternLength = 200`. The length check
// runs BEFORE the duplicate check so an over-cap dup-of-existing entry
// surfaces the more specific length-cap copy from S2 §L.6 rather than
// the duplicate copy.
//
// The validator is a pure (input → outcome) function so the
// rejection-copy contract can be pinned in unit tests without driving
// a SwiftUI host. The view-side `.onSubmit` closure in
// `SearchAndRedactSheet.swift` calls this and routes the result into
// `duplicateTermMessage` (the existing term-rejection banner channel)
// or appends the term to `searchState.searchTerms`.

extension SearchAndRedactSheet {

    /// Per-term cap mirrored from `DocumentSearcher.maxRegexPatternLength`.
    /// Inlined as a named constant so the test pin reads as `200` and
    /// the engine-side cap can change independently without silently
    /// loosening this gate.
    static let multiTermMaxLength = 200

    /// Outcome of validating a single submitted multi-term entry.
    /// `.accepted(trimmed)` carries the trimmed string ready to append;
    /// every rejection case carries the exact banner copy a view should
    /// surface through the term-rejection channel (`duplicateTermMessage`).
    enum MultiTermSubmissionOutcome: Equatable {
        case accepted(trimmed: String)
        case rejectedEmpty
        case rejectedTooLong(message: String)
        case rejectedDuplicate(message: String)
    }

    /// Validate a single submission against the multi-term TextField rules.
    /// Order: empty → length → duplicate. The length check runs BEFORE
    /// the duplicate check so an over-cap dup-of-existing entry surfaces
    /// the more specific length-cap copy.
    ///
    /// Banner copy is S2 §L.6 verbatim per Jesse decision Q4 (resolved).
    ///
    /// `nonisolated` because the body is pure string + array work and
    /// the Pkg G.3 unit tests call it off the main thread. Without this,
    /// the implicit @MainActor inherited from the SwiftUI View extension
    /// trips Swift 6.2's runtime executor check inside the
    /// `contains(where:)` closure.
    nonisolated static func validateMultiTermSubmission(
        rawText: String,
        existingTerms: [String]
    ) -> MultiTermSubmissionOutcome {
        let trimmed = rawText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return .rejectedEmpty }
        guard trimmed.count <= multiTermMaxLength else {
            return .rejectedTooLong(
                message: "Search term is too long. Trim to 200 characters or fewer."
            )
        }
        let isDuplicate = existingTerms.contains {
            $0.caseInsensitiveCompare(trimmed) == .orderedSame
        }
        if isDuplicate {
            return .rejectedDuplicate(
                message: "Already searching for \"\(trimmed)\""
            )
        }
        return .accepted(trimmed: trimmed)
    }
}
