import Foundation

// W-P — Custom Terms × shipped-asset merge layer per §D16 = P1
// (user always wins). V1 flat-N1 special case: every entry keys on
// (category: nil, doctype: nil, surfaceForm: term.pattern.normalized)
// because the V1 UserTerm model is (pattern, isRegex) — see STRAT §1.5
// "UserTerm shape" + §5.3 stop-conditions. Per-(category, doctype)
// keying surface is reserved for V1.1+ when UserTerm grows
// `category: PIICategory?` / `doctype: DoctypeClass?` fields.

public struct UserTermsIndex: Sendable {

    public enum Decision: Sendable, Equatable {
        case alwaysFlag(pattern: String)
        case neverFlag(pattern: String)
        case none
    }

    public struct Key: Hashable, Sendable {
        public let category: PIICategory?    // V1: always nil
        public let doctype: DoctypeClass?    // V1: always nil
        public let surfaceForm: String       // lowercased, normalized

        public init(
            category: PIICategory? = nil,
            doctype: DoctypeClass? = nil,
            surfaceForm: String
        ) {
            self.category = category
            self.doctype = doctype
            self.surfaceForm = surfaceForm
        }
    }

    // V1 backing: parallel literal sets (mirrors UserTermMatcher's internal
    // split on regex vs. literal). Per-key Decision lookup is O(1) on the
    // literal path; regex path stays linear over the matcher's own regex
    // list. UserTermMatcher remains the actual matching engine — this type
    // is the keying-surface envelope.
    private let matcher: UserTermMatcher

    public init(matcher: UserTermMatcher) {
        self.matcher = matcher
    }

    /// Convenience: compile + wrap in one shot. Mirrors
    /// `UserTermMatcher.compile(alwaysFlag:neverFlag:)`.
    public static func compile(
        alwaysFlag: [UserTerm],
        neverFlag: [UserTerm]
    ) -> UserTermsIndex {
        UserTermsIndex(matcher: .compile(
            alwaysFlag: alwaysFlag, neverFlag: neverFlag
        ))
    }

    public var isEmpty: Bool { matcher.isEmpty }

    /// Resolve a single matched-text candidate to a Decision under the
    /// V1 flat-N1 keying. `category` and `doctype` are accepted in the
    /// signature for V1.1+ scoping but ignored in V1 (per the flat-N1
    /// special case). Never-flag wins over always-flag if both fire —
    /// defensive; the UI prevents conflicts at insertion, but the engine
    /// stays robust against persisted blobs that drifted.
    public func decision(
        for matchedText: String,
        category: PIICategory? = nil,
        doctype: DoctypeClass? = nil
    ) -> Decision {
        if let pat = matcher.shouldSuppress(matchedText) {
            return .neverFlag(pattern: pat)
        }
        if let pat = matcher.matchesAlwaysFlag(matchedText) {
            return .alwaysFlag(pattern: pat)
        }
        return .none
    }

    /// Apply never-flag suppression to a sequence of detector matches
    /// before threshold filtering. Called from
    /// `DocumentSearcher.searchPII()` between `resolveOverlaps` and
    /// `applying(thresholdVector:)`. `doctype` is forwarded for V1.1+
    /// scoping; ignored in V1.
    public func merge(
        into matches: [PIIDetector.PIIMatch],
        doctype: DoctypeClass?
    ) -> [PIIDetector.PIIMatch] {
        guard !matcher.isEmpty else { return matches }
        return matches.filter { match in
            switch decision(for: match.text, category: match.category, doctype: doctype) {
            case .neverFlag: return false        // suppress pre-threshold
            case .alwaysFlag, .none: return true
            }
        }
    }

    /// Pass-through accessor so `searchPII()` can keep using the
    /// always-flag synthetic emission path unchanged.
    public var underlyingMatcher: UserTermMatcher { matcher }
}
