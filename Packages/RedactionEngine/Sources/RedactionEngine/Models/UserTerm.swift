import Foundation

// W3 — user-defined custom keyword. Consumed by `UserTermMatcher` during
// PII scans and persisted globally by `SettingsState.customUserTerms`.
//
// Length and regex-validity are NOT enforced on the struct — enforcement
// happens at UI insertion and at `UserTermMatcher.compile(...)` time, so
// stored blobs from prior versions whose terms exceed the cap or contain
// a pattern the validator now rejects are silently dropped on load rather
// than crashing.
public struct UserTerm: Sendable, Codable, Equatable, Hashable {
    public let pattern: String
    public let isRegex: Bool

    public init(pattern: String, isRegex: Bool) {
        self.pattern = pattern
        self.isRegex = isRegex
    }
}
