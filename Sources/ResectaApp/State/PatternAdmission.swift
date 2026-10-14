import Foundation
import RedactionEngine

/// The one path a user-typed regex takes before a store commits it: the
/// sentinel probe, then the store's own commit. Every surface that admits
/// a pattern calls here, so the probe's entry and the refusal copy live in
/// one place; a surface whose store runs the syntax pre-check at commit
/// calls the probe alone.
enum PatternAdmission {

    /// What admitting a pattern into a store came to.
    enum Outcome: Equatable {
        case added
        case refused(message: String)
    }

    /// The sentinel's refusal copy: the catalog string every surface shows.
    static var sentinelRejectedMessage: String {
        String(localized: "profile.regex.sentinel.rejected", table: "Legal", bundle: .main)
    }

    /// The store's refusal copy: the synchronous pre-check, a cap or a
    /// label collision.
    static let storeRejectedMessage = "Pattern rejected. Check the syntax, length, or label uniqueness."

    /// The sentinel probe alone. `false` means the pattern is refused with
    /// `sentinelRejectedMessage`.
    static func sentinelAdmits(_ pattern: String) async -> Bool {
        await RegexSentinelCheck.validate(pattern)
    }

    /// Sentinel, then commit: the saved-regex library's add.
    static func admit(label: String, pattern: String, into store: SavedRegexStore) async -> Outcome {
        guard await sentinelAdmits(pattern) else {
            return .refused(message: sentinelRejectedMessage)
        }
        return store.add(label: label, pattern: pattern)
            ? .added
            : .refused(message: storeRejectedMessage)
    }
}
